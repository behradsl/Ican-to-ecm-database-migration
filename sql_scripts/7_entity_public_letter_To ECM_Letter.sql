IF OBJECT_ID('master.dbo.Migration_IcanLetter_RahkaranLetter_Map', 'U') IS NOT NULL
BEGIN
    DROP TABLE master.dbo.Migration_IcanLetter_RahkaranLetter_Map;
END
GO

CREATE TABLE master.dbo.Migration_IcanLetter_RahkaranLetter_Map
(
    Ican_EntityCode INT PRIMARY KEY,
    Rahkaran_LetterID BIGINT NOT NULL,
    CreatorIcanUserID INT NULL,
    MigrationDate DATETIME DEFAULT GETDATE()
);
GO

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @LastID BIGINT;
    SELECT @LastID = LastID
    FROM {{RAHKARAN_DB}}.SYS3.TableIdGen WITH (UPDLOCK, HOLDLOCK)
    WHERE TableName = 'ECM.Letter';

    IF @LastID IS NULL
        THROW 50001, 'TableIdGen row not found for ECM.Letter', 1;

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
        RegistrationDate  DATETIME  NULL
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
            MU.CorrespondentID,
            ROW_NUMBER() OVER (ORDER BY L.EntityCode) AS RN
        FROM {{ICAN_DB}}.dbo.Entity_public_letter L
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
        [Subject], CreationDate, LastEditDate, RegistrationDate
    )
    SELECT
        EntityCode, @LastID + RN + 1 AS Rahkaran_LetterID, CreatorID, CorrespondentID,
        [Subject], CreationDate, LastEditDate, RegistrationDate
    FROM Src;

    INSERT INTO {{RAHKARAN_DB}}.ECM.Letter
    (
        LetterID, LetterType, CreatorRef, SenderRef, ActorRef, Language, State, Subject,
        Description, Creator, CreationDate, LastModifier, LastModificationDate, HasContent,
        DistributedByECE, HasAttachment, RegistrationDate
    )
    SELECT
        B.Rahkaran_LetterID, 1, B.CorrespondentID, B.CorrespondentID, B.CorrespondentID,
        1, 1, B.[Subject], N'ican convert', 1, ISNULL(B.CreationDate, GETDATE()),
        1, ISNULL(B.LastEditDate, ISNULL(B.CreationDate, GETDATE())), 0, 0, 0, B.RegistrationDate
    FROM #LetterBatch B;

    DECLARE @InsertedCount BIGINT = @@ROWCOUNT;

    INSERT INTO master.dbo.Migration_IcanLetter_RahkaranLetter_Map
    (
        Ican_EntityCode, Rahkaran_LetterID, CreatorIcanUserID
    )
    SELECT B.Ican_EntityCode, B.Rahkaran_LetterID, B.CreatorIcanUserID
    FROM #LetterBatch B;

    UPDATE {{RAHKARAN_DB}}.SYS3.TableIdGen
    SET LastID = @LastID + @InsertedCount
    WHERE TableName = 'ECM.Letter';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

select * from {{RAHKARAN_DB}}.ecm.LetterReceiver;