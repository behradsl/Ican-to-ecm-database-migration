BEGIN TRY
    BEGIN TRANSACTION;

    PRINT 'Step 9: Creating Missing Parties for Unknown Receivers...';

    IF OBJECT_ID('tempdb..#MissingCompanies') IS NOT NULL DROP TABLE #MissingCompanies;

    -- 1. Gather unique unmapped Company names
    -- FIXED: Rahkaran's GNR3.Party.CompanyName strictly allows only 100 characters.
    CREATE TABLE #MissingCompanies (
        CompanyName NVARCHAR(100) PRIMARY KEY,
        PartyId BIGINT NULL
    );

    -- FIXED: Truncate the ICAN string to 100 characters so it fits legally
    INSERT INTO #MissingCompanies (CompanyName)
    SELECT DISTINCT CAST(LetterRecipientTO AS NVARCHAR(100))
    FROM master.dbo.Migration_Staging_LetterReceivers
    WHERE ResolvedCorrespondentID IS NULL 
      AND LetterRecipientTO IS NOT NULL;

    DECLARE @MissingCount INT;
    SELECT @MissingCount = COUNT(*) FROM #MissingCompanies;

    IF @MissingCount > 0
    BEGIN
        -- 2. Match to existing Rahkaran Parties (Type 1 = Company)
        UPDATE mc
        SET mc.PartyId = p.PartyID
        FROM #MissingCompanies mc
        INNER JOIN [{{RAHKARAN_DB}}].[GNR3].[Party] p 
            ON LTRIM(RTRIM(p.CompanyName)) COLLATE DATABASE_DEFAULT = mc.CompanyName COLLATE DATABASE_DEFAULT
           AND p.[Type] = 1;

        -- 3. Prepare to Insert truly missing Parties
        DECLARE @NewPartiesCount BIGINT;
        SELECT @NewPartiesCount = COUNT(*) FROM #MissingCompanies WHERE PartyId IS NULL;

        IF @NewPartiesCount > 0
        BEGIN
            DECLARE @CurrentPartyId BIGINT;
            SELECT @CurrentPartyId = ISNULL(LastId, 0) FROM [{{RAHKARAN_DB}}].[SYS3].[TableIdGen] WITH (UPDLOCK) WHERE TableName = 'gnr3.party';

            IF OBJECT_ID('tempdb..#NewParties') IS NOT NULL DROP TABLE #NewParties;
            SELECT 
                CompanyName,
                @CurrentPartyId + ROW_NUMBER() OVER(ORDER BY CompanyName) AS NewPartyId
            INTO #NewParties
            FROM #MissingCompanies WHERE PartyId IS NULL;

            -- Insert the new Parties
            INSERT INTO [{{RAHKARAN_DB}}].[GNR3].[Party] (
                PartyID, CompanyName, [Type], Creator, CreationDate, LastModifier, LastModificationDate, CompanyName_EN
            )
            SELECT 
                NewPartyId, CompanyName, 1, 1, GETDATE(), 1, GETDATE(), 'icanConvert'
            FROM #NewParties;

            -- Update Generator
            UPDATE [{{RAHKARAN_DB}}].[SYS3].[TableIdGen] 
            SET LastId = @CurrentPartyId + @NewPartiesCount 
            WHERE TableName = 'gnr3.party';
        END
    END

    COMMIT TRANSACTION;
    PRINT 'Step 9 Complete. Missing Parties Created.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO