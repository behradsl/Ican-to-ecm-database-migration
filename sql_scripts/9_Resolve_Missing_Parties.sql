BEGIN TRY
    BEGIN TRANSACTION;

    PRINT 'Step 9: Creating Missing Parties for Unknown / Free-Text Receivers...';

    IF OBJECT_ID('tempdb..#MissingCompanies') IS NOT NULL DROP TABLE #MissingCompanies;

    -- Party.CompanyName max length is 100
    CREATE TABLE #MissingCompanies (
        CompanyName NVARCHAR(100) PRIMARY KEY,
        PartyId BIGINT NULL
    );

    -- Distinct resolve names from unresolved staging (includes -1 / empty RecipientType captions)
    INSERT INTO #MissingCompanies (CompanyName)
    SELECT DISTINCT ResolvePartyName
    FROM master.dbo.Migration_Staging_LetterReceivers
    WHERE ResolvedCorrespondentID IS NULL
      AND ResolvePartyName IS NOT NULL
      AND LTRIM(RTRIM(ResolvePartyName)) <> N'';

    DECLARE @MissingCount INT;
    SELECT @MissingCount = COUNT(*) FROM #MissingCompanies;
    PRINT 'Distinct unresolved party names: ' + CAST(@MissingCount AS VARCHAR);

    IF @MissingCount > 0
    BEGIN
        -- Match existing company parties (Type 1 = company in GNR3.Party)
        UPDATE mc
        SET mc.PartyId = p.PartyID
        FROM #MissingCompanies mc
        INNER JOIN [{{RAHKARAN_DB}}].[GNR3].[Party] p 
            ON LTRIM(RTRIM(p.CompanyName)) COLLATE DATABASE_DEFAULT
             = mc.CompanyName COLLATE DATABASE_DEFAULT
           AND p.[Type] = 1;

        -- Also match person parties by FirstName+LastName (no space) or FirstName + ' ' + LastName
        UPDATE mc
        SET mc.PartyId = p.PartyID
        FROM #MissingCompanies mc
        INNER JOIN [{{RAHKARAN_DB}}].[GNR3].[Party] p 
            ON p.[Type] = 0
           AND (
                LTRIM(RTRIM(ISNULL(p.FirstName, N'') + ISNULL(p.LastName, N''))) COLLATE DATABASE_DEFAULT
                    = mc.CompanyName COLLATE DATABASE_DEFAULT
                OR LTRIM(RTRIM(ISNULL(p.FirstName, N'') + N' ' + ISNULL(p.LastName, N''))) COLLATE DATABASE_DEFAULT
                    = mc.CompanyName COLLATE DATABASE_DEFAULT
           )
        WHERE mc.PartyId IS NULL;

        DECLARE @MatchedCount BIGINT;
        DECLARE @NewPartiesCount BIGINT;
        SELECT @MatchedCount = COUNT(*) FROM #MissingCompanies WHERE PartyId IS NOT NULL;
        SELECT @NewPartiesCount = COUNT(*) FROM #MissingCompanies WHERE PartyId IS NULL;
        PRINT 'Matched existing parties: ' + CAST(@MatchedCount AS VARCHAR)
            + ', to insert: ' + CAST(@NewPartiesCount AS VARCHAR);

        IF @NewPartiesCount > 0
        BEGIN
            DECLARE @CurrentPartyId BIGINT;
            SELECT @CurrentPartyId = LastId
            FROM [{{RAHKARAN_DB}}].[SYS3].[TableIdGen] WITH (UPDLOCK)
            WHERE TableName = 'gnr3.party';

            IF @CurrentPartyId IS NULL
            BEGIN
                SET @CurrentPartyId = 0;
                IF NOT EXISTS (
                    SELECT 1 FROM [{{RAHKARAN_DB}}].[SYS3].[TableIdGen]
                    WHERE TableName = 'gnr3.party'
                )
                    INSERT INTO [{{RAHKARAN_DB}}].[SYS3].[TableIdGen] (TableName, LastId)
                    VALUES ('gnr3.party', 0);
            END

            IF OBJECT_ID('tempdb..#NewParties') IS NOT NULL DROP TABLE #NewParties;
            SELECT 
                CompanyName,
                @CurrentPartyId + ROW_NUMBER() OVER(ORDER BY CompanyName) AS NewPartyId
            INTO #NewParties
            FROM #MissingCompanies WHERE PartyId IS NULL;

            -- Insert as company parties (Type 1); step 5 SP creates Correspondents (Type 2)
            INSERT INTO [{{RAHKARAN_DB}}].[GNR3].[Party] (
                PartyID, CompanyName, [Type], Creator, CreationDate,
                LastModifier, LastModificationDate, CompanyName_EN
            )
            SELECT 
                NewPartyId, CompanyName, 1, 1, GETDATE(),
                1, GETDATE(), 'icanConvert'
            FROM #NewParties;

            UPDATE [{{RAHKARAN_DB}}].[SYS3].[TableIdGen] 
            SET LastId = @CurrentPartyId + @NewPartiesCount 
            WHERE TableName = 'gnr3.party';

            -- Keep #MissingCompanies in sync for clarity
            UPDATE mc
            SET mc.PartyId = np.NewPartyId
            FROM #MissingCompanies mc
            INNER JOIN #NewParties np ON np.CompanyName = mc.CompanyName;
        END
    END

    COMMIT TRANSACTION;
    PRINT 'Step 9 Complete. Missing Parties Created for free-text / unresolved receivers.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
