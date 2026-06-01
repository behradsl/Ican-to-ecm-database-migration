/* ===============================================================
   ICAN.Department -> RahkaranSG.GNR3.Party
   Migration Type: Company Party
   =============================================================== */

/* ===============================================================
   STEP 0: ENSURE PERMANENT MAPPING TABLE EXISTS
   =============================================================== */
IF OBJECT_ID('dbo.Migration_IcanDepartment_RahkaranParty_Map', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Migration_IcanDepartment_RahkaranParty_Map (
        ICAN_Department_ID INT NOT NULL PRIMARY KEY,
        Rahkaran_PartyID BIGINT NOT NULL
    );
END
GO

BEGIN TRY
    BEGIN TRANSACTION;

    /* ===============================================================
       STAGE 1: TEMP MATCH TABLE
       =============================================================== */
    IF OBJECT_ID('tempdb..#MatchedDepartments') IS NOT NULL
        DROP TABLE #MatchedDepartments;

    CREATE TABLE #MatchedDepartments (
        ICAN_Department_ID INT NOT NULL PRIMARY KEY,
        Rahkaran_PartyID BIGINT NOT NULL
    );

    /* ===============================================================
       PHASE 1-A: MATCH EXISTING PARTIES BY COMPANY NAME
       =============================================================== */
    INSERT INTO #MatchedDepartments (
        ICAN_Department_ID,
        Rahkaran_PartyID
    )
    SELECT
        x.ICAN_Department_ID,
        x.Rahkaran_PartyID
    FROM (
        SELECT
            D.Department_ID AS ICAN_Department_ID,
            P.PartyID AS Rahkaran_PartyID,
            ROW_NUMBER() OVER (
                PARTITION BY D.Department_ID
                ORDER BY P.PartyID
            ) AS rn
        FROM [ican].[dbo].[Departments] D
        INNER JOIN [RahkaranSG].[GNR3].[Party] P
            ON LTRIM(RTRIM(D.DepartmentName)) COLLATE DATABASE_DEFAULT
             = LTRIM(RTRIM(P.CompanyName)) COLLATE DATABASE_DEFAULT   
			 or 
			  LTRIM(RTRIM(D.DepartmentName)) COLLATE DATABASE_DEFAULT
             = LTRIM(RTRIM(P.FirstName)) + LTRIM(RTRIM(P.LastName)) COLLATE DATABASE_DEFAULT 
        WHERE D.DepartmentName IS NOT NULL
          AND LTRIM(RTRIM(D.DepartmentName)) <> ''
          AND NOT EXISTS (
                SELECT 1
                FROM dbo.Migration_IcanDepartment_RahkaranParty_Map M
                WHERE M.ICAN_Department_ID = D.Department_ID
          )
    ) x
    WHERE x.rn = 1;

    /* ===============================================================
       SAVE MATCHED RECORDS
       =============================================================== */
    INSERT INTO dbo.Migration_IcanDepartment_RahkaranParty_Map (
        ICAN_Department_ID,
        Rahkaran_PartyID
    )
    SELECT
        ICAN_Department_ID,
        Rahkaran_PartyID
    FROM #MatchedDepartments;

    /* ===============================================================
       PHASE 2: FIND NON-MIGRATED DEPARTMENTS
       =============================================================== */
    IF OBJECT_ID('tempdb..#NewDepartments') IS NOT NULL
        DROP TABLE #NewDepartments;

    SELECT
        D.*
    INTO #NewDepartments
    FROM [ican].[dbo].[Departments] D
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.Migration_IcanDepartment_RahkaranParty_Map M
        WHERE M.ICAN_Department_ID = D.Department_ID
    );

    DECLARE @RecordCount BIGINT;

    SELECT @RecordCount = COUNT(*)
    FROM #NewDepartments;

    /* ===============================================================
       PHASE 3: INSERT NEW PARTY RECORDS
       =============================================================== */
    IF @RecordCount > 0
    BEGIN

        DECLARE @CurrentLastId BIGINT;

        SELECT @CurrentLastId = LastId
        FROM [RahkaranSG].[SYS3].[TableIdGen] WITH (UPDLOCK, ROWLOCK)
        WHERE TableName = 'gnr3.party';

        IF OBJECT_ID('tempdb..#PreparedPartyDep') IS NOT NULL
            DROP TABLE #PreparedPartyDep;

        SELECT
            D.Department_ID AS ICAN_Department_ID,

            @CurrentLastId
            + ROW_NUMBER() OVER (
                ORDER BY D.Department_ID
            ) AS Generated_PartyID,

            D.DepartmentName
        INTO #PreparedPartyDep
        FROM #NewDepartments D;

        /* ===========================================================
           INSERT INTO GNR3.Party
           Type = 1 => Company
           =========================================================== */
        INSERT INTO [RahkaranSG].[GNR3].[Party] (
            PartyID,
            CompanyName,
            [Type],
            Creator,
            CreationDate,
            LastModifier,
            LastModificationDate,
			CompanyName_EN
        )
        SELECT
            Generated_PartyID,
            DepartmentName,
            1,
            1,
            GETDATE(),
            1,
            GETDATE(),
			'icanConvert'
        FROM #PreparedPartyDep;

        /* ===========================================================
           UPDATE TABLE ID GENERATOR
           =========================================================== */
        UPDATE [RahkaranSG].[SYS3].[TableIdGen]
        SET LastId = @CurrentLastId + @RecordCount
        WHERE TableName = 'gnr3.party';

        /* ===========================================================
           SAVE GENERATED MAPPINGS
           =========================================================== */
        INSERT INTO dbo.Migration_IcanDepartment_RahkaranParty_Map (
            ICAN_Department_ID,
            Rahkaran_PartyID
        )
        SELECT
            ICAN_Department_ID,
            Generated_PartyID
        FROM #PreparedPartyDep;

    END

    COMMIT TRANSACTION;

    PRINT N'✅ Department migration completed successfully.';

END TRY
BEGIN CATCH

    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    PRINT N'❌ Error occurred. Transaction rolled back.';
    PRINT ERROR_MESSAGE();

END CATCH;


