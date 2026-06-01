/* ===============================================================
   STEP 0: ENSURE PERMANENT MAPPING TABLE EXISTS
   =============================================================== */
IF OBJECT_ID('dbo.Migration_UserParty_Map', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Migration_UserParty_Map (
        ican_Department_ID     INT     NOT NULL PRIMARY KEY,
        Rahkaran_PartyID BIGINT  NOT NULL
    );
END
GO

BEGIN TRY
    BEGIN TRANSACTION;

    /* ===============================================================
       STAGE 1: TEMP MATCH TABLE
       =============================================================== */
    IF OBJECT_ID('tempdb..#MatchedUsers') IS NOT NULL DROP TABLE #MatchedUsers;

    CREATE TABLE #MatchedUsers (
        ican_Department_ID     INT     NOT NULL PRIMARY KEY,
        Rahkaran_PartyID BIGINT  NOT NULL
    );

    /* ===============================================================
       PHASE 1-A: MATCH BY NATIONAL ID (DEDUPED)
       =============================================================== */
    INSERT INTO #MatchedUsers (ican_Department_ID, Rahkaran_PartyID)
    SELECT ican_Department_ID, Rahkaran_PartyID
    FROM (
        SELECT
            U.User_ID AS ican_Department_ID,
            P.PartyID AS Rahkaran_PartyID,
            ROW_NUMBER() OVER (
                PARTITION BY U.User_ID
                ORDER BY P.PartyID
            ) AS rn
        FROM [ican].[dbo].[Users] U
        JOIN [RahkaranSG].[GNR3].[Party] P
            ON U.NativeID COLLATE DATABASE_DEFAULT
             = P.NationalID COLLATE DATABASE_DEFAULT
        WHERE U.NativeID IS NOT NULL
          AND U.NativeID <> ''
          AND NOT EXISTS (
              SELECT 1
              FROM dbo.Migration_UserParty_Map M
              WHERE M.ican_Department_ID = U.User_ID
          )
    ) x
    WHERE rn = 1;

    /* ===============================================================
       PHASE 1-B: MATCH BY FIRST + LAST NAME (DEDUPED)
       =============================================================== */
    INSERT INTO #MatchedUsers (ican_Department_ID, Rahkaran_PartyID)
    SELECT ican_Department_ID, Rahkaran_PartyID
    FROM (
        SELECT
            U.User_ID AS ican_Department_ID,
            P.PartyID AS Rahkaran_PartyID,
            ROW_NUMBER() OVER (
                PARTITION BY U.User_ID
                ORDER BY P.PartyID
            ) AS rn
        FROM [ican].[dbo].[Users] U
        JOIN [RahkaranSG].[GNR3].[Party] P
            ON LTRIM(RTRIM(U.FirstName)) COLLATE DATABASE_DEFAULT
             = LTRIM(RTRIM(P.FirstName)) COLLATE DATABASE_DEFAULT
           AND LTRIM(RTRIM(U.LastName)) COLLATE DATABASE_DEFAULT
             = LTRIM(RTRIM(P.LastName)) COLLATE DATABASE_DEFAULT
        WHERE NOT EXISTS (
              SELECT 1 FROM #MatchedUsers M
              WHERE M.ican_Department_ID = U.User_ID
          )
          AND NOT EXISTS (
              SELECT 1 FROM dbo.Migration_UserParty_Map M
              WHERE M.ican_Department_ID = U.User_ID
          )
    ) x
    WHERE rn = 1;

    /* ===============================================================
       SAVE MATCHES
       =============================================================== */
    INSERT INTO dbo.Migration_UserParty_Map (ican_Department_ID, Rahkaran_PartyID)
    SELECT ican_Department_ID, Rahkaran_PartyID
    FROM #MatchedUsers;

    /* ===============================================================
       PHASE 2: INSERT NEW USERS
       =============================================================== */
    IF OBJECT_ID('tempdb..#NewUsers') IS NOT NULL DROP TABLE #NewUsers;

    SELECT *
    INTO #NewUsers
    FROM [ican].[dbo].[Users] U
    WHERE NOT EXISTS (
        SELECT 1
        FROM dbo.Migration_UserParty_Map M
        WHERE M.ican_Department_ID = U.User_ID
    );

    DECLARE @RecordCount BIGINT;
    SELECT @RecordCount = COUNT(*) FROM #NewUsers;

    IF @RecordCount > 0
    BEGIN
        DECLARE @CurrentLastId BIGINT;

        SELECT @CurrentLastId = LastId
        FROM [RahkaranSG].[SYS3].[TableIdGen] WITH (UPDLOCK, ROWLOCK)
        WHERE TableName = 'gnr3.Party';

        IF OBJECT_ID('tempdb..#PreparedParty') IS NOT NULL DROP TABLE #PreparedParty;

        SELECT
            U.User_ID AS ican_Department_ID,
            @CurrentLastId + ROW_NUMBER() OVER (ORDER BY U.User_ID) AS Generated_PartyID,
            U.FirstName,
            U.LastName,
            U.NativeID,
            U.Mobile
        INTO #PreparedParty
        FROM #NewUsers U;

        INSERT INTO [RahkaranSG].[GNR3].[Party] (
            PartyID, FirstName, LastName, NationalID, Mobile,
            [Type], Creator, CreationDate, LastModifier, LastModificationDate
        )
        SELECT
            Generated_PartyID, FirstName, LastName, NativeID, Mobile,
            0, 1, GETDATE(), 1, GETDATE()
        FROM #PreparedParty;

        UPDATE [RahkaranSG].[SYS3].[TableIdGen]
        SET LastId = @CurrentLastId + @RecordCount
        WHERE TableName = 'gnr3.party';

        INSERT INTO dbo.Migration_UserParty_Map (ican_Department_ID, Rahkaran_PartyID)
        SELECT ican_Department_ID, Generated_PartyID
        FROM #PreparedParty;
    END

    COMMIT TRANSACTION;
    PRINT '✅ Migration and mapping completed successfully.';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT '❌ Error occurred. Transaction rolled back.';
    PRINT ERROR_MESSAGE();
END CATCH;
