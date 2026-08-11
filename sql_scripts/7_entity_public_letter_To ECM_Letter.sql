-- 1. Create the mapping table ONLY if it doesn't exist. Never drop it!
IF OBJECT_ID('master.dbo.Migration_IcanLetter_RahkaranLetter_Map', 'U') IS NULL
BEGIN
    CREATE TABLE master.dbo.Migration_IcanLetter_RahkaranLetter_Map
    (
        Ican_EntityCode INT PRIMARY KEY,
        Rahkaran_LetterID BIGINT NOT NULL,
        CreatorIcanUserID INT NULL,
        MigrationDate DATETIME DEFAULT GETDATE()
    );
    PRINT 'Created mapping table.';
END
ELSE
BEGIN
    PRINT 'Mapping table already exists. Upserting letters...';
END
GO

BEGIN TRY
    BEGIN TRANSACTION;

    /* ===============================================================
       UPSERT EXISTING: refresh letter fields for already-mapped rows
       =============================================================== */
    UPDATE Ltr
    SET
        Ltr.[Subject] = Src.[Subject],
        Ltr.CreationDate = ISNULL(Src.CreationDate, Ltr.CreationDate),
        Ltr.LastModificationDate = ISNULL(Src.LastEditDate, ISNULL(Src.CreationDate, Ltr.LastModificationDate)),
        Ltr.RegistrationDate = Src.RegistrationDate,
        Ltr.RegistrationNumber = Src.EntityNumber,
        Ltr.LastModifier = 1,
        -- Keep CreatorRef/SenderRef/ActorRef in sync if creator mapping is available
        Ltr.CreatorRef = ISNULL(Src.CorrespondentID, Ltr.CreatorRef),
        Ltr.SenderRef = ISNULL(Src.CorrespondentID, Ltr.SenderRef),
        Ltr.ActorRef = ISNULL(Src.CorrespondentID, Ltr.ActorRef)
    FROM [{{RAHKARAN_DB}}].ECM.Letter Ltr
    INNER JOIN master.dbo.Migration_IcanLetter_RahkaranLetter_Map M
        ON M.Rahkaran_LetterID = Ltr.LetterID
    INNER JOIN (
        SELECT
            L.EntityCode,
            L.[Subject],
            L.CreationDate,
            L.LastEditDate,
            L.[Date] AS RegistrationDate,
            L.EntityNumber,
            MU.CorrespondentID
        FROM [{{ICAN_DB}}].dbo.Entity_public_letter L
        LEFT JOIN master.dbo.Migration_UserParty_Map MU
            ON MU.Ican_User_ID = L.CreatorID
    ) Src ON Src.EntityCode = M.Ican_EntityCode;

    DECLARE @UpdatedCount BIGINT = @@ROWCOUNT;
    PRINT CAST(@UpdatedCount AS VARCHAR) + ' existing letters updated from ICAN.';

    -- Also refresh CreatorIcanUserID on the map if it was null / changed
    UPDATE M
    SET
        M.CreatorIcanUserID = L.CreatorID
    FROM master.dbo.Migration_IcanLetter_RahkaranLetter_Map M
    INNER JOIN [{{ICAN_DB}}].dbo.Entity_public_letter L
        ON L.EntityCode = M.Ican_EntityCode
    WHERE M.CreatorIcanUserID IS NULL
       OR M.CreatorIcanUserID <> L.CreatorID;

    /* ===============================================================
       INSERT MISSING: only letters not yet in the mapping table
       =============================================================== */
    DECLARE @LastID BIGINT;
    SELECT @LastID = LastID
    FROM [{{RAHKARAN_DB}}].SYS3.TableIdGen WITH (UPDLOCK, HOLDLOCK)
    WHERE TableName = 'ECM.Letter';

    IF @LastID IS NULL
    BEGIN
        SET @LastID = 0; 
        INSERT INTO [{{RAHKARAN_DB}}].SYS3.TableIdGen (TableName, LastID)
        VALUES ('ECM.Letter', @LastID);
    END

    IF OBJECT_ID('tempdb..#LetterBatch') IS NOT NULL DROP TABLE #LetterBatch;

    CREATE TABLE #LetterBatch
    (
        Ican_EntityCode   INT       NOT NULL PRIMARY KEY,
        Rahkaran_LetterID BIGINT    NOT NULL,
        CreatorIcanUserID INT       NULL,
        CorrespondentID   BIGINT    NOT NULL,
        [Subject]         NVARCHAR(MAX) NULL,
        CreationDate      DATETIME  NULL,
        LastEditDate      DATETIME  NULL,
        RegistrationDate  DATETIME  NULL,
        EntityNumber      NVARCHAR(MAX) NULL    
    );

    ;WITH Src AS
    (
        SELECT
            L.EntityCode,
            L.CreatorID,
            L.[Subject],
            L.CreationDate,
            L.LastEditDate,
            L.[Date] AS RegistrationDate,
            L.EntityNumber,
            MU.CorrespondentID,
            ROW_NUMBER() OVER (ORDER BY L.EntityCode) AS RN
        FROM [{{ICAN_DB}}].dbo.Entity_public_letter L
        JOIN master.dbo.Migration_UserParty_Map MU
            ON MU.Ican_User_ID = L.CreatorID
        WHERE MU.CorrespondentID IS NOT NULL
          AND NOT EXISTS
          (
              SELECT 1
              FROM master.dbo.Migration_IcanLetter_RahkaranLetter_Map M
              WHERE M.Ican_EntityCode = L.EntityCode
          )
    )
    INSERT INTO #LetterBatch
    (
        Ican_EntityCode, Rahkaran_LetterID, CreatorIcanUserID, CorrespondentID,
        [Subject], CreationDate, LastEditDate, RegistrationDate, EntityNumber
    )
    SELECT
        EntityCode, @LastID + RN AS Rahkaran_LetterID, CreatorID, CorrespondentID,
        [Subject], CreationDate, LastEditDate, RegistrationDate, EntityNumber
    FROM Src;

    DECLARE @InsertedCount BIGINT;
    SELECT @InsertedCount = COUNT(*) FROM #LetterBatch;

    IF @InsertedCount > 0
    BEGIN
        PRINT CAST(@InsertedCount AS VARCHAR) + ' new letters found. Inserting into Rahkaran...';

        INSERT INTO [{{RAHKARAN_DB}}].ECM.Letter
        (
            LetterID, LetterType, CreatorRef, SenderRef, ActorRef, Language, State, Subject,
            Description, Creator, CreationDate, LastModifier, LastModificationDate, HasContent,
            DistributedByECE, HasAttachment, RegistrationDate, SecuretyLevelRef, UrgencyRef, RegistrationNumber 
        )
        SELECT
            B.Rahkaran_LetterID, 1, B.CorrespondentID, B.CorrespondentID, B.CorrespondentID,
            1, 5, B.[Subject], N'ican convert', 1, ISNULL(B.CreationDate, GETDATE()),
            1, ISNULL(B.LastEditDate, ISNULL(B.CreationDate, GETDATE())), 0, 0, 0, B.RegistrationDate, 1, 1, B.EntityNumber
        FROM #LetterBatch B;

        INSERT INTO master.dbo.Migration_IcanLetter_RahkaranLetter_Map
        (
            Ican_EntityCode, Rahkaran_LetterID, CreatorIcanUserID
        )
        SELECT B.Ican_EntityCode, B.Rahkaran_LetterID, B.CreatorIcanUserID
        FROM #LetterBatch B;

        UPDATE [{{RAHKARAN_DB}}].SYS3.TableIdGen
        SET LastID = @LastID + @InsertedCount
        WHERE TableName = 'ECM.Letter';
    END
    ELSE
    BEGIN
        PRINT 'No new letters to migrate. All mappable ICAN letters are already in Rahkaran.';
    END

    COMMIT TRANSACTION;
    PRINT '✅ Letter upsert complete. Updated: '
        + CAST(@UpdatedCount AS VARCHAR)
        + ', Inserted: ' + CAST(ISNULL(@InsertedCount, 0) AS VARCHAR);
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
