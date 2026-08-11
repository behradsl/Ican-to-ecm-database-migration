/* ===============================================================
   STEP 0: ENSURE PERMANENT MAPPING TABLE EXISTS IN MASTER
   Never drop — production maps must survive re-runs.
   =============================================================== */
IF OBJECT_ID('master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map', 'U') IS NULL
BEGIN
    CREATE TABLE master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map (
        ICAN_OrganizationRole_ID INT NOT NULL PRIMARY KEY,
        Rahkaran_PartyID BIGINT NOT NULL
    );
    PRINT 'Created Migration_IcanOrganizationRole_RahkaranParty_Map.';
END
ELSE
BEGIN
    PRINT 'Migration_IcanOrganizationRole_RahkaranParty_Map already exists. Upserting...';
END
GO

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID('tempdb..#MatchedOrganizationRoles') IS NOT NULL
        DROP TABLE #MatchedOrganizationRoles;

    CREATE TABLE #MatchedOrganizationRoles (
        ICAN_OrganizationRole_ID INT NOT NULL PRIMARY KEY,
        Rahkaran_PartyID BIGINT NOT NULL
    );

    INSERT INTO #MatchedOrganizationRoles (
        ICAN_OrganizationRole_ID, Rahkaran_PartyID
    )
    SELECT x.ICAN_OrganizationRole_ID, x.Rahkaran_PartyID
    FROM (
        SELECT
            ORG.OrganizationRole_ID AS ICAN_OrganizationRole_ID,
            P.PartyID AS Rahkaran_PartyID,
            ROW_NUMBER() OVER (
                PARTITION BY ORG.OrganizationRole_ID
                ORDER BY P.PartyID
            ) AS rn
        FROM [{{ICAN_DB}}].[dbo].[OrganizationRoles] ORG
        INNER JOIN [{{RAHKARAN_DB}}].[GNR3].[Party] P
            ON LTRIM(RTRIM(ORG.OrganizationRoleName)) COLLATE DATABASE_DEFAULT
             = LTRIM(RTRIM(P.CompanyName)) COLLATE DATABASE_DEFAULT
        WHERE ORG.OrganizationRoleName IS NOT NULL
          AND LTRIM(RTRIM(ORG.OrganizationRoleName)) <> ''
          AND NOT EXISTS (
                SELECT 1
                FROM master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map M
                WHERE M.ICAN_OrganizationRole_ID = ORG.OrganizationRole_ID
          )
    ) x
    WHERE x.rn = 1;

    INSERT INTO master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map (
        ICAN_OrganizationRole_ID, Rahkaran_PartyID
    )
    SELECT ICAN_OrganizationRole_ID, Rahkaran_PartyID
    FROM #MatchedOrganizationRoles;

    IF OBJECT_ID('tempdb..#NewOrganizationRoles') IS NOT NULL
        DROP TABLE #NewOrganizationRoles;

    SELECT ORG.*
    INTO #NewOrganizationRoles
    FROM [{{ICAN_DB}}].[dbo].[OrganizationRoles] ORG
    WHERE NOT EXISTS (
        SELECT 1
        FROM master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map M
        WHERE M.ICAN_OrganizationRole_ID = ORG.OrganizationRole_ID
    );

    DECLARE @RecordCount BIGINT;
    SELECT @RecordCount = COUNT(*) FROM #NewOrganizationRoles;

    IF @RecordCount > 0
    BEGIN

        DECLARE @CurrentLastId BIGINT;
        SELECT @CurrentLastId = LastId
        FROM [{{RAHKARAN_DB}}].[SYS3].[TableIdGen] WITH (UPDLOCK, ROWLOCK)
        WHERE TableName = 'gnr3.party';

        IF @CurrentLastId IS NULL
        BEGIN
            SET @CurrentLastId = 0;
            INSERT INTO [{{RAHKARAN_DB}}].[SYS3].[TableIdGen] (TableName, LastId)
            VALUES ('gnr3.party', @CurrentLastId);
        END

        IF OBJECT_ID('tempdb..#PreparedPartyOrg') IS NOT NULL
            DROP TABLE #PreparedPartyOrg;

        SELECT
            ORG.OrganizationRole_ID AS ICAN_OrganizationRole_ID,
            @CurrentLastId + ROW_NUMBER() OVER (ORDER BY ORG.OrganizationRole_ID) AS Generated_PartyID,
            ORG.OrganizationRoleName
        INTO #PreparedPartyOrg
        FROM #NewOrganizationRoles ORG;

        INSERT INTO [{{RAHKARAN_DB}}].[GNR3].[Party] (
            PartyID, CompanyName, [Type], Creator, CreationDate,
            LastModifier, LastModificationDate, CompanyName_EN
        )
        SELECT
            Generated_PartyID, OrganizationRoleName, 1, 1, GETDATE(),
            1, GETDATE(), 'icanConvert'
        FROM #PreparedPartyOrg;

        UPDATE [{{RAHKARAN_DB}}].[SYS3].[TableIdGen]
        SET LastId = @CurrentLastId + @RecordCount
        WHERE TableName = 'gnr3.party';

        INSERT INTO master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map (
            ICAN_OrganizationRole_ID, Rahkaran_PartyID
        )
        SELECT ICAN_OrganizationRole_ID, Generated_PartyID
        FROM #PreparedPartyOrg;

    END

    -- Upsert: refresh company name on mapped org-role parties
    UPDATE P
    SET
        P.CompanyName = ORG.OrganizationRoleName,
        P.LastModifier = 1,
        P.LastModificationDate = GETDATE()
    FROM [{{RAHKARAN_DB}}].[GNR3].[Party] P
    INNER JOIN master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map M
        ON M.Rahkaran_PartyID = P.PartyID
    INNER JOIN [{{ICAN_DB}}].[dbo].[OrganizationRoles] ORG
        ON ORG.OrganizationRole_ID = M.ICAN_OrganizationRole_ID;

    DECLARE @UpdatedCount INT = @@ROWCOUNT;

    COMMIT TRANSACTION;
    PRINT N'✅ OrganizationRole→Party upsert completed. Inserted new: '
        + CAST(ISNULL(@RecordCount, 0) AS NVARCHAR)
        + N', Updated existing: ' + CAST(@UpdatedCount AS NVARCHAR);

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
