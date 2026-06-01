/* ===============================================================
   ICAN.OrganizationRole -> RahkaranSG.GNR3.Party
   Migration Type: Company Party
   =============================================================== */

/* ===============================================================
   STEP 0: ENSURE PERMANENT MAPPING TABLE EXISTS
   =============================================================== */

IF OBJECT_ID('dbo.Migration_IcanOrganizationRole_RahkaranParty_Map', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Migration_IcanOrganizationRole_RahkaranParty_Map (
        ICAN_OrganizationRole_ID INT NOT NULL PRIMARY KEY,
        Rahkaran_PartyID BIGINT NOT NULL
    );
END
GO

BEGIN TRY
    BEGIN TRANSACTION;

    /* ===============================================================
       STAGE 1: TEMP MATCH TABLE
       =============================================================== */
    IF OBJECT_ID('tempdb..#MatchedOrganizationRoles') IS NOT NULL
        DROP TABLE #MatchedOrganizationRoles;

    CREATE TABLE #MatchedOrganizationRoles (
        ICAN_OrganizationRole_ID INT NOT NULL PRIMARY KEY,
        Rahkaran_PartyID BIGINT NOT NULL
    );

    /* ===============================================================
       PHASE 1-A: MATCH EXISTING PARTIES BY COMPANY NAME
       =============================================================== */
    INSERT INTO #MatchedOrganizationRoles (
        ICAN_OrganizationRole_ID,
        Rahkaran_PartyID
    )
    SELECT
        x.ICAN_OrganizationRole_ID,
        x.Rahkaran_PartyID
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
                FROM dbo.Migration_IcanOrganizationRole_RahkaranParty_Map M
                WHERE M.ICAN_OrganizationRole_ID = ORG.OrganizationRole_ID
          )
    ) x
    WHERE x.rn = 1;

    /* ===============================================================
       SAVE MATCHED RECORDS
       =============================================================== */
    INSERT INTO dbo.Migration_IcanOrganizationRole_RahkaranParty_Map (
        ICAN_OrganizationRole_ID,
        Rahkaran_PartyID
    )
    SELECT
        ICAN_OrganizationRole_ID,
        Rahkaran_PartyID
    FROM #MatchedOrganizationRoles;

    /* ===============================================================
       PHASE 2: FIND NON-MIGRATED ORGANIZATION ROLES
       =============================================================== */
    IF OBJECT_ID('tempdb..#NewOrganizationRoles') IS NOT NULL
        DROP TABLE #NewOrganizationRoles;

    SELECT
        ORG.*
    INTO #NewOrganizationRoles
    FROM [{{ICAN_DB}}].[dbo].[OrganizationRoles] ORG
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.Migration_IcanOrganizationRole_RahkaranParty_Map M
        WHERE M.ICAN_OrganizationRole_ID = ORG.OrganizationRole_ID
    );

    DECLARE @RecordCount BIGINT;

    SELECT @RecordCount = COUNT(*)
    FROM #NewOrganizationRoles;

    /* ===============================================================
       PHASE 3: INSERT NEW PARTY RECORDS
       =============================================================== */
    IF @RecordCount > 0
    BEGIN

        DECLARE @CurrentLastId BIGINT;

        SELECT @CurrentLastId = LastId
        FROM [{{RAHKARAN_DB}}].[SYS3].[TableIdGen] WITH (UPDLOCK, ROWLOCK)
        WHERE TableName = 'gnr3.party';

        IF OBJECT_ID('tempdb..#PreparedPartyOrg') IS NOT NULL
            DROP TABLE #PreparedPartyOrg;

        SELECT
            ORG.OrganizationRole_ID AS ICAN_OrganizationRole_ID,

            @CurrentLastId
            + ROW_NUMBER() OVER (
                ORDER BY ORG.OrganizationRole_ID
            ) AS Generated_PartyID,

            ORG.OrganizationRoleName
        INTO #PreparedPartyOrg
        FROM #NewOrganizationRoles ORG;

        /* ===========================================================
           INSERT INTO GNR3.Party
           Type = 1 => Company
           =========================================================== */
        INSERT INTO [{{RAHKARAN_DB}}].[GNR3].[Party] (
            PartyID,
            CompanyName,
            [Type],
            Creator,
            CreationDate,
            LastModifier,
            LastModificationDate
			,CompanyName_EN
        )
        SELECT
            Generated_PartyID,
            OrganizationRoleName,
            1,
            1,
            GETDATE(),
            1,
            GETDATE()
			,'icanConvert'
        FROM #PreparedPartyOrg;

        /* ===========================================================
           UPDATE TABLE ID GENERATOR
           =========================================================== */
        UPDATE [{{RAHKARAN_DB}}].[SYS3].[TableIdGen]
        SET LastId = @CurrentLastId + @RecordCount
        WHERE TableName = 'gnr3.party';

        /* ===========================================================
           SAVE GENERATED MAPPINGS
           =========================================================== */
        INSERT INTO dbo.Migration_IcanOrganizationRole_RahkaranParty_Map (
            ICAN_OrganizationRole_ID,
            Rahkaran_PartyID
        )
        SELECT
            ICAN_OrganizationRole_ID,
            Generated_PartyID
        FROM #PreparedPartyOrg;

    END

    COMMIT TRANSACTION;

    PRINT N'✅ OrganizationRole migration completed successfully.';

END TRY
BEGIN CATCH

    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT N'❌ Error occurred. Transaction rolled back.';
    PRINT ERROR_MESSAGE();

END CATCH;
