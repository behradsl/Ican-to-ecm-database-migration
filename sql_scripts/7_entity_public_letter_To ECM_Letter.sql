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
    PRINT 'Mapping table already exists. Resuming migration...';
END
GO

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @LastID BIGINT;
    SELECT @LastID = LastID
    FROM [{{RAHKARAN_DB}}].SYS3.TableIdGen WITH (UPDLOCK, HOLDLOCK)
    WHERE TableName = 'ECM.Letter';

    -- If no record exists, initialize with 0 and insert it.
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
          -- THIS IS THE SKIP LOGIC: Only select letters that are NOT in the mapping table
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

    -- Only proceed with Inserts if we actually have new letters to migrate!
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

        -- Save the successfully inserted letters to the mapping table so we never insert them again
        INSERT INTO master.dbo.Migration_IcanLetter_RahkaranLetter_Map
        (
            Ican_EntityCode, Rahkaran_LetterID, CreatorIcanUserID
        )
        SELECT B.Ican_EntityCode, B.Rahkaran_LetterID, B.CreatorIcanUserID
        FROM #LetterBatch B;

        -- Bump the ID Generator forward
        UPDATE [{{RAHKARAN_DB}}].SYS3.TableIdGen
        SET LastID = @LastID + @InsertedCount
        WHERE TableName = 'ECM.Letter';
    END
    ELSE
    BEGIN
        PRINT 'No new letters to migrate. All ICAN letters are already in Rahkaran.';
    END

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO