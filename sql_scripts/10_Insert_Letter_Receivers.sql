BEGIN TRY
    BEGIN TRANSACTION;

    PRINT 'Step 10: Mapping Final Correspondents and Upserting Receivers...';

    -- 1a. Resolve via company Party (GNR3.Type=1) -> Correspondent Type 2 (CompanyPartyRef)
    --     Covers free-text ResolvePartyName and legacy LetterRecipientTO matches.
    UPDATE S
    SET ResolvedCorrespondentID = c.CorrespondentID
    FROM master.dbo.Migration_Staging_LetterReceivers S
    INNER JOIN [{{RAHKARAN_DB}}].[GNR3].[Party] p 
        ON p.[Type] = 1
       AND LTRIM(RTRIM(p.CompanyName)) COLLATE DATABASE_DEFAULT
         = COALESCE(S.ResolvePartyName, CAST(S.LetterRecipientTO AS NVARCHAR(100))) COLLATE DATABASE_DEFAULT
    INNER JOIN [{{RAHKARAN_DB}}].[ECM].[Correspondent] c 
        ON c.CompanyPartyRef = p.PartyID AND c.[Type] = 2 AND c.State = 1
    WHERE S.ResolvedCorrespondentID IS NULL
      AND COALESCE(S.ResolvePartyName, CAST(S.LetterRecipientTO AS NVARCHAR(100))) IS NOT NULL;

    -- 1b. Resolve via person Party (GNR3.Type=0) -> Correspondent Type 1 (PartyRef)
    UPDATE S
    SET ResolvedCorrespondentID = c.CorrespondentID
    FROM master.dbo.Migration_Staging_LetterReceivers S
    INNER JOIN [{{RAHKARAN_DB}}].[GNR3].[Party] p 
        ON p.[Type] = 0
       AND (
            LTRIM(RTRIM(ISNULL(p.FirstName, N'') + ISNULL(p.LastName, N''))) COLLATE DATABASE_DEFAULT
                = S.ResolvePartyName COLLATE DATABASE_DEFAULT
            OR LTRIM(RTRIM(ISNULL(p.FirstName, N'') + N' ' + ISNULL(p.LastName, N''))) COLLATE DATABASE_DEFAULT
                = S.ResolvePartyName COLLATE DATABASE_DEFAULT
       )
    INNER JOIN [{{RAHKARAN_DB}}].[ECM].[Correspondent] c 
        ON c.PartyRef = p.PartyID AND c.[Type] = 1 AND c.State = 1
    WHERE S.ResolvedCorrespondentID IS NULL
      AND S.ResolvePartyName IS NOT NULL;

    DECLARE @StillUnresolved INT;
    SELECT @StillUnresolved = COUNT(*)
    FROM master.dbo.Migration_Staging_LetterReceivers
    WHERE ResolvedCorrespondentID IS NULL;
    PRINT 'Staging rows still unresolved after name match: '
        + CAST(ISNULL(@StillUnresolved, 0) AS VARCHAR);

    -- 2. Setup ID Generator for LetterReceiver
    DECLARE @LastID BIGINT;
    SELECT @LastID = LastID
    FROM {{RAHKARAN_DB}}.SYS3.TableIdGen WITH (UPDLOCK, HOLDLOCK)
    WHERE TableName = 'ECM.LetterReceiver';

    IF @LastID IS NULL
    BEGIN
        SET @LastID = 0; 
        INSERT INTO {{RAHKARAN_DB}}.SYS3.TableIdGen (TableName, LastID)
        VALUES ('ECM.LetterReceiver', @LastID);
    END

    IF OBJECT_ID('tempdb..#CandidateReceivers') IS NOT NULL DROP TABLE #CandidateReceivers;
    IF OBJECT_ID('tempdb..#FinalReceiversToInsert') IS NOT NULL DROP TABLE #FinalReceiversToInsert;

    -- 3. Dedup candidate receivers for migrated letters
    -- Prefer full cleaned Caption as title; fall back to ResolvePartyName / To.
    SELECT DISTINCT 
        LM.Rahkaran_LetterID AS LetterRef, 
        S.ResolvedCorrespondentID AS ReceiverRef, 
        CAST(
            COALESCE(
                NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(
                    S.RecipientCaption,
                    N'<br/>', N' '),
                    N'<br />', N' '),
                    N'&lt;br/&gt;', N' '))), N''),
                S.ResolvePartyName,
                NULLIF(LTRIM(RTRIM(S.LetterRecipientTO)), N'')
            ) AS NVARCHAR(250)
        ) AS ReceiverTitle
    INTO #CandidateReceivers
    FROM master.dbo.Migration_Staging_LetterReceivers S
    INNER JOIN master.dbo.Migration_IcanLetter_RahkaranLetter_Map LM
        ON LM.Ican_EntityCode = S.Ican_EntityCode
    WHERE S.ResolvedCorrespondentID IS NOT NULL;

    -- 4. Upsert existing: refresh ReceiverTitle on already-present receivers
    UPDATE LR
    SET
        LR.ReceiverTitle = C.ReceiverTitle,
        LR.LastModifier = 1,
        LR.LastModificationDate = GETDATE()
    FROM {{RAHKARAN_DB}}.ECM.LetterReceiver LR
    INNER JOIN #CandidateReceivers C
        ON C.LetterRef = LR.LetterRef
       AND C.ReceiverRef = LR.ReceiverRef
       AND LR.[Type] = 1
       AND LR.[Order] = 1
    WHERE ISNULL(LR.ReceiverTitle, N'') COLLATE DATABASE_DEFAULT
       <> ISNULL(C.ReceiverTitle, N'') COLLATE DATABASE_DEFAULT;

    DECLARE @UpdatedCount BIGINT = @@ROWCOUNT;

    -- 5. Insert only missing receivers; assign contiguous new IDs
    SELECT
        C.LetterRef,
        C.ReceiverRef,
        C.ReceiverTitle,
        ROW_NUMBER() OVER (ORDER BY C.LetterRef, C.ReceiverRef) AS RN
    INTO #FinalReceiversToInsert
    FROM #CandidateReceivers C
    WHERE NOT EXISTS (
        SELECT 1
        FROM {{RAHKARAN_DB}}.ECM.LetterReceiver LR
        WHERE LR.LetterRef = C.LetterRef
          AND LR.ReceiverRef = C.ReceiverRef
          AND LR.[Type] = 1
          AND LR.[Order] = 1
    );

    DECLARE @InsertedCount BIGINT;
    SELECT @InsertedCount = COUNT(*) FROM #FinalReceiversToInsert;

    IF @InsertedCount > 0
    BEGIN
        INSERT INTO {{RAHKARAN_DB}}.ECM.LetterReceiver (
            LetterReceiverID, LetterRef, ReceiverRef, [Type], [Order], [Description],
            Creator, CreationDate, LastModifier, LastModificationDate, ReceiverTitle
        )
        SELECT
            @LastID + R.RN, R.LetterRef, R.ReceiverRef, 1, 1, NULL, 
            1, GETDATE(), 1, GETDATE(), R.ReceiverTitle
        FROM #FinalReceiversToInsert R;

        UPDATE {{RAHKARAN_DB}}.SYS3.TableIdGen
        SET LastID = @LastID + @InsertedCount
        WHERE TableName = 'ECM.LetterReceiver';
    END

    -- 6. LetterType is set in step 7 from import/export/internal classification.

    -- 7. Denormalize receiver titles onto Letter.ReciversName as title1-title2-title3
    ;WITH Agg AS
    (
        SELECT
            LR.LetterRef,
            STRING_AGG(CAST(LR.ReceiverTitle AS NVARCHAR(MAX)), N'-')
                WITHIN GROUP (ORDER BY LR.[Order], LR.LetterReceiverID) AS ReciversName
        FROM {{RAHKARAN_DB}}.ECM.LetterReceiver LR
        INNER JOIN master.dbo.Migration_IcanLetter_RahkaranLetter_Map M
            ON M.Rahkaran_LetterID = LR.LetterRef
        WHERE LR.ReceiverTitle IS NOT NULL
          AND LTRIM(RTRIM(LR.ReceiverTitle)) <> N''
        GROUP BY LR.LetterRef
    )
    UPDATE L
    SET
        L.ReciversName = A.ReciversName,
        L.LastModifier = 1,
        L.LastModificationDate = GETDATE()
    FROM {{RAHKARAN_DB}}.ECM.Letter L
    INNER JOIN Agg A
        ON A.LetterRef = L.LetterID;

    DECLARE @ReciversNameUpdated BIGINT = @@ROWCOUNT;
    PRINT 'ReciversName refreshed on ' + CAST(@ReciversNameUpdated AS VARCHAR) + ' letters.';

    -- Keep letter ID generator at least at max(LetterID)
    DECLARE @MaxLetterID BIGINT;
    SELECT @MaxLetterID = ISNULL(MAX(LetterID), 0) FROM {{RAHKARAN_DB}}.ECM.Letter;

    UPDATE {{RAHKARAN_DB}}.SYS3.TableIdGen
    SET LastID = CASE WHEN @MaxLetterID > LastID THEN @MaxLetterID ELSE LastID END
    WHERE TableName = 'ECM.Letter';

    COMMIT TRANSACTION;
    PRINT 'Step 10 Complete. Receivers updated: '
        + CAST(@UpdatedCount AS VARCHAR)
        + ', inserted: ' + CAST(ISNULL(@InsertedCount, 0) AS VARCHAR);
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
