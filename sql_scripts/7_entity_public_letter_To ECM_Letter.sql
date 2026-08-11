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
       Build classified source (import / export / internal)
       LetterType lookup (SYS3.Lookup Type='LetterType'):
         1 = وارده (incoming), 2 = صادره (outgoing), 3 = داخلی (internal)
       Registration number priority:
         export -> ExportEntityNumber
         import -> ImportEntityNumber
         internal -> EntityNumber
       When both import & export exist, prefer export (صادره).
       =============================================================== */
    IF OBJECT_ID('tempdb..#LetterSrc') IS NOT NULL DROP TABLE #LetterSrc;

    SELECT
        L.EntityCode,
        L.CreatorID,
        L.[Subject],
        L.CreationDate,
        L.LastEditDate,
        MU.CorrespondentID,
        /* classification flags */
        CASE WHEN I.EntityCode IS NOT NULL THEN 1 ELSE 0 END AS IsImport,
        CASE
            WHEN E.EntityCode IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(L.ExportEntityNumber)), N'') IS NOT NULL THEN 1
            ELSE 0
        END AS IsExport,
        /* resolved register number */
        CASE
            WHEN E.EntityCode IS NOT NULL
              OR NULLIF(LTRIM(RTRIM(L.ExportEntityNumber)), N'') IS NOT NULL
            THEN COALESCE(
                    NULLIF(LTRIM(RTRIM(E.ExportEntityNumber)), N''),
                    NULLIF(LTRIM(RTRIM(L.ExportEntityNumber)), N''),
                    NULLIF(LTRIM(RTRIM(L.EntityNumber)), N'')
                 )
            WHEN I.EntityCode IS NOT NULL
            THEN COALESCE(
                    NULLIF(LTRIM(RTRIM(I.ImportEntityNumber)), N''),
                    NULLIF(LTRIM(RTRIM(L.ImportEntityNumber)), N''),
                    NULLIF(LTRIM(RTRIM(L.EntityNumber)), N'')
                 )
            ELSE NULLIF(LTRIM(RTRIM(L.EntityNumber)), N'')
        END AS RegistrationNumber,
        /* resolved register date */
        CASE
            WHEN E.EntityCode IS NOT NULL
              OR NULLIF(LTRIM(RTRIM(L.ExportEntityNumber)), N'') IS NOT NULL
            THEN COALESCE(E.ExportDate, L.ExportDate, L.[Date], L.CreationDate)
            WHEN I.EntityCode IS NOT NULL
            THEN COALESCE(I.ImportDate, L.ImportDate, L.[Date], L.CreationDate)
            ELSE COALESCE(L.[Date], L.CreationDate)
        END AS RegistrationDate,
        /* LetterType: export wins over import when both */
        CASE
            WHEN E.EntityCode IS NOT NULL
              OR NULLIF(LTRIM(RTRIM(L.ExportEntityNumber)), N'') IS NOT NULL
            THEN 2  -- صادره
            WHEN I.EntityCode IS NOT NULL
            THEN 1  -- وارده
            ELSE 3  -- داخلی
        END AS LetterType
    INTO #LetterSrc
    FROM [{{ICAN_DB}}].dbo.Entity_public_letter L
    LEFT JOIN [{{ICAN_DB}}].dbo.Entity_public_import I
        ON I.EntityCode = L.EntityCode
    LEFT JOIN [{{ICAN_DB}}].dbo.Entity_public_export E
        ON E.EntityCode = L.EntityCode
    LEFT JOIN master.dbo.Migration_UserParty_Map MU
        ON MU.Ican_User_ID = L.CreatorID;

    /* ===============================================================
       UPSERT EXISTING: refresh letter fields for already-mapped rows
       =============================================================== */
    UPDATE Ltr
    SET
        Ltr.[Subject] = Src.[Subject],
        Ltr.CreationDate = ISNULL(Src.CreationDate, Ltr.CreationDate),
        Ltr.LastModificationDate = ISNULL(Src.LastEditDate, ISNULL(Src.CreationDate, Ltr.LastModificationDate)),
        Ltr.RegistrationDate = Src.RegistrationDate,
        Ltr.RegistrationNumber = LEFT(Src.RegistrationNumber, 200),
        Ltr.LetterType = Src.LetterType,
        Ltr.LastModifier = 1,
        Ltr.CreatorRef = ISNULL(Src.CorrespondentID, Ltr.CreatorRef),
        Ltr.SenderRef = ISNULL(Src.CorrespondentID, Ltr.SenderRef),
        Ltr.ActorRef = ISNULL(Src.CorrespondentID, Ltr.ActorRef)
    FROM [{{RAHKARAN_DB}}].ECM.Letter Ltr
    INNER JOIN master.dbo.Migration_IcanLetter_RahkaranLetter_Map M
        ON M.Rahkaran_LetterID = Ltr.LetterID
    INNER JOIN #LetterSrc Src
        ON Src.EntityCode = M.Ican_EntityCode;

    DECLARE @UpdatedCount BIGINT = @@ROWCOUNT;
    PRINT CAST(@UpdatedCount AS VARCHAR) + ' existing letters updated from ICAN.';

    UPDATE M
    SET M.CreatorIcanUserID = L.CreatorID
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
        Ican_EntityCode     INT           NOT NULL PRIMARY KEY,
        Rahkaran_LetterID   BIGINT        NOT NULL,
        CreatorIcanUserID   INT           NULL,
        CorrespondentID     BIGINT        NOT NULL,
        [Subject]           NVARCHAR(MAX) NULL,
        CreationDate        DATETIME      NULL,
        LastEditDate        DATETIME      NULL,
        RegistrationDate    DATETIME      NULL,
        RegistrationNumber  NVARCHAR(MAX) NULL,
        LetterType          INT           NOT NULL
    );

    ;WITH Src AS
    (
        SELECT
            S.EntityCode,
            S.CreatorID,
            S.[Subject],
            S.CreationDate,
            S.LastEditDate,
            S.RegistrationDate,
            S.RegistrationNumber,
            S.LetterType,
            S.CorrespondentID,
            ROW_NUMBER() OVER (ORDER BY S.EntityCode) AS RN
        FROM #LetterSrc S
        WHERE S.CorrespondentID IS NOT NULL
          AND NOT EXISTS
          (
              SELECT 1
              FROM master.dbo.Migration_IcanLetter_RahkaranLetter_Map M
              WHERE M.Ican_EntityCode = S.EntityCode
          )
    )
    INSERT INTO #LetterBatch
    (
        Ican_EntityCode, Rahkaran_LetterID, CreatorIcanUserID, CorrespondentID,
        [Subject], CreationDate, LastEditDate, RegistrationDate, RegistrationNumber, LetterType
    )
    SELECT
        EntityCode, @LastID + RN, CreatorID, CorrespondentID,
        [Subject], CreationDate, LastEditDate, RegistrationDate, RegistrationNumber, LetterType
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
            B.Rahkaran_LetterID, B.LetterType, B.CorrespondentID, B.CorrespondentID, B.CorrespondentID,
            1, 5, B.[Subject], N'ican convert', 1, ISNULL(B.CreationDate, GETDATE()),
            1, ISNULL(B.LastEditDate, ISNULL(B.CreationDate, GETDATE())), 0, 0, 0,
            B.RegistrationDate, 1, 1, LEFT(B.RegistrationNumber, 200)
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

    -- Summary by type
    SELECT
        LetterType,
        COUNT(*) AS Cnt
    INTO #TypeSummary
    FROM #LetterSrc
    WHERE CorrespondentID IS NOT NULL
    GROUP BY LetterType;

    PRINT 'LetterType plan (mappable): '
        + ISNULL((SELECT ' وارده(1)=' + CAST(Cnt AS VARCHAR) FROM #TypeSummary WHERE LetterType = 1), N' وارده(1)=0')
        + ISNULL((SELECT ' صادره(2)=' + CAST(Cnt AS VARCHAR) FROM #TypeSummary WHERE LetterType = 2), N' صادره(2)=0')
        + ISNULL((SELECT ' داخلی(3)=' + CAST(Cnt AS VARCHAR) FROM #TypeSummary WHERE LetterType = 3), N' داخلی(3)=0');

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
