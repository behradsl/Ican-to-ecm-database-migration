/* ===============================================================
   STEP 0: ENSURE PERMANENT MAPPING TABLE EXISTS IN MASTER
   =============================================================== */
IF OBJECT_ID('master.dbo.Migration_IcanDepartment_RahkaranParty_Map', 'U') IS NOT NULL
BEGIN
    DROP TABLE master.dbo.Migration_IcanDepartment_RahkaranParty_Map;
END
GO

CREATE TABLE master.dbo.Migration_IcanDepartment_RahkaranParty_Map (
    ICAN_Department_ID INT NOT NULL PRIMARY KEY,
    Rahkaran_PartyID BIGINT NOT NULL
);
GO

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID('tempdb..#MatchedDepartments') IS NOT NULL
        DROP TABLE #MatchedDepartments;

    CREATE TABLE #MatchedDepartments (
        ICAN_Department_ID INT NOT NULL PRIMARY KEY,
        Rahkaran_PartyID BIGINT NOT NULL
    );

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
        FROM [{{ICAN_DB}}].[dbo].[Departments] D
        INNER JOIN [{{RAHKARAN_DB}}].[GNR3].[Party] P
            ON LTRIM(RTRIM(D.DepartmentName)) COLLATE DATABASE_DEFAULT
             = LTRIM(RTRIM(P.CompanyName)) COLLATE DATABASE_DEFAULT   
			 or 
			  LTRIM(RTRIM(D.DepartmentName)) COLLATE DATABASE_DEFAULT
             = LTRIM(RTRIM(P.FirstName)) + LTRIM(RTRIM(P.LastName)) COLLATE DATABASE_DEFAULT 
        WHERE D.DepartmentName IS NOT NULL
          AND LTRIM(RTRIM(D.DepartmentName)) <> ''
          AND NOT EXISTS (
                SELECT 1
                FROM master.dbo.Migration_IcanDepartment_RahkaranParty_Map M
                WHERE M.ICAN_Department_ID = D.Department_ID
          )
    ) x
    WHERE x.rn = 1;

    INSERT INTO master.dbo.Migration_IcanDepartment_RahkaranParty_Map (
        ICAN_Department_ID,
        Rahkaran_PartyID
    )
    SELECT
        ICAN_Department_ID,
        Rahkaran_PartyID
    FROM #MatchedDepartments;

    IF OBJECT_ID('tempdb..#NewDepartments') IS NOT NULL
        DROP TABLE #NewDepartments;

    SELECT
        D.*
    INTO #NewDepartments
    FROM [{{ICAN_DB}}].[dbo].[Departments] D
    WHERE NOT EXISTS (
        SELECT 1
        FROM master.dbo.Migration_IcanDepartment_RahkaranParty_Map M
        WHERE M.ICAN_Department_ID = D.Department_ID
    );

    DECLARE @RecordCount BIGINT;

    SELECT @RecordCount = COUNT(*)
    FROM #NewDepartments;

    IF @RecordCount > 0
    BEGIN

        DECLARE @CurrentLastId BIGINT;

        SELECT @CurrentLastId = LastId
        FROM [{{RAHKARAN_DB}}].[SYS3].[TableIdGen] WITH (UPDLOCK, ROWLOCK)
        WHERE TableName = 'gnr3.party';

        IF OBJECT_ID('tempdb..#PreparedPartyDep') IS NOT NULL
            DROP TABLE #PreparedPartyDep;

        SELECT
            D.Department_ID AS ICAN_Department_ID,
            @CurrentLastId + ROW_NUMBER() OVER (ORDER BY D.Department_ID) AS Generated_PartyID,
            D.DepartmentName
        INTO #PreparedPartyDep
        FROM #NewDepartments D;

        INSERT INTO [{{RAHKARAN_DB}}].[GNR3].[Party] (
            PartyID, CompanyName, [Type], Creator, CreationDate, LastModifier, LastModificationDate, CompanyName_EN
        )
        SELECT
            Generated_PartyID, DepartmentName, 1, 1, GETDATE(), 1, GETDATE(), 'icanConvert'
        FROM #PreparedPartyDep;

        UPDATE [{{RAHKARAN_DB}}].[SYS3].[TableIdGen]
        SET LastId = @CurrentLastId + @RecordCount
        WHERE TableName = 'gnr3.party';

        INSERT INTO master.dbo.Migration_IcanDepartment_RahkaranParty_Map (
            ICAN_Department_ID, Rahkaran_PartyID
        )
        SELECT ICAN_Department_ID, Generated_PartyID
        FROM #PreparedPartyDep;

    END

    COMMIT TRANSACTION;
    PRINT N'✅ Department migration completed successfully.';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;