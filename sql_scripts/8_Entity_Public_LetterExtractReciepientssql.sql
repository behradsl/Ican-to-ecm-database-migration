-- 1. Create the temporary table (if not already created)
IF OBJECT_ID('tempdb..#TempLetterReceivers') IS NOT NULL DROP TABLE #TempLetterReceivers;

CREATE TABLE #TempLetterReceivers (
    EntityCode INT,
    RecipientType NVARCHAR(50),
    RecipientID INT
);

-- 2. Shred the XML and insert into the temp table
INSERT INTO #TempLetterReceivers (EntityCode, RecipientType, RecipientID)
SELECT 
    e.EntityCode,
    T.c.value('@RecipientType', 'NVARCHAR(50)') AS RecipientType,
    T.c.value('@RecipientID', 'INT') AS RecipientID
FROM 
    [{{ICAN_DB}}].[dbo].[Entity_public_letter] e
-- Step A: Cast the UDT MultiPersonnelField to NVARCHAR(MAX), then to XML
CROSS APPLY 
    (SELECT CAST(CAST(e.[Receivers] AS NVARCHAR(MAX)) AS XML) AS XmlData) AS CastedData
-- Step B: Call .nodes() on the newly created XML column alias
CROSS APPLY 
    CastedData.XmlData.nodes('/Receivers/Receiver') AS T(c)
WHERE 
    e.[Receivers] IS NOT NULL;

-- 3. Verify the inserted data
SELECT top(10)* 
FROM #TempLetterReceivers;


BEGIN TRY
    BEGIN TRANSACTION;

    -------------------------------------------------------------------------
    -- 1) Lock and read LastID for ECM.LetterReciever
    -------------------------------------------------------------------------
    DECLARE @LastID BIGINT;

    SELECT @LastID = LastID
    FROM {{RAHKARAN_DB}}.SYS3.TableIdGen WITH (UPDLOCK, HOLDLOCK)
    WHERE TableName = 'ECM.LetterReceiver';   -- keep your spelling here

    IF @LastID IS NULL
        THROW 50001, 'TableIdGen row not found for ECM.LetterReciever', 1;

    -------------------------------------------------------------------------
    -- 2) Extract receivers XML -> temp table
    -------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#TempLetterReceivers') IS NOT NULL
        DROP TABLE #TempLetterReceivers;

    CREATE TABLE #TempLetterReceivers
    (
        EntityCode     INT           NOT NULL,
        RecipientType  NVARCHAR(50)  NOT NULL,
        RecipientID    INT           NOT NULL
    );

    INSERT INTO #TempLetterReceivers (EntityCode, RecipientType, RecipientID)
    SELECT
        e.EntityCode,
        T.c.value('@RecipientType', 'NVARCHAR(50)') AS RecipientType,
        T.c.value('@RecipientID',   'INT')          AS RecipientID
    FROM {{ICAN_DB}}.dbo.Entity_public_letter e
    CROSS APPLY (SELECT CAST(CAST(e.Receivers AS NVARCHAR(MAX)) AS XML) AS XmlData) X
    CROSS APPLY X.XmlData.nodes('/Receivers/Receiver') AS T(c)
    WHERE e.Receivers IS NOT NULL;

    -------------------------------------------------------------------------
    -- 3) Resolve ReceiverRef via mapping tables (CorrespondentID already set)
    --    friend is ignored
    -------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Resolved') IS NOT NULL
        DROP TABLE #Resolved;

    CREATE TABLE #Resolved
    (
        Rahkaran_LetterID BIGINT       NOT NULL,
        ReceiverRef       BIGINT       NOT NULL,
        ReceiverTitle     NVARCHAR(500) NULL,
        RN                BIGINT       NOT NULL
    );

    ;WITH R AS
    (
        -- department
        SELECT
            LM.Rahkaran_LetterID,
            D.CorrespondentID AS ReceiverRef,
            CAST(NULL AS NVARCHAR(500)) AS ReceiverTitle
        FROM #TempLetterReceivers TR
        JOIN dbo.Migration_IcanLetter_RahkaranLetter_Map LM
            ON LM.Ican_EntityCode = TR.EntityCode
        JOIN dbo.Migration_IcanDepartment_RahkaranParty_Map D
            ON D.Ican_Department_ID = TR.RecipientID   -- <-- rename if different
        WHERE LOWER(TR.RecipientType) = 'department'
          AND D.CorrespondentID IS NOT NULL

        UNION ALL

        -- role
        SELECT
            LM.Rahkaran_LetterID,
            P.CorrespondentID AS ReceiverRef,
            CAST(NULL AS NVARCHAR(500)) AS ReceiverTitle
        FROM #TempLetterReceivers TR
        JOIN dbo.Migration_IcanLetter_RahkaranLetter_Map LM
            ON LM.Ican_EntityCode = TR.EntityCode
        JOIN dbo.Migration_IcanRoles_RahkaranPost_Map P
            ON P.Ican_Role_ID = TR.RecipientID         -- <-- rename if different
        WHERE LOWER(TR.RecipientType) = 'role'
          AND P.CorrespondentID IS NOT NULL

        UNION ALL

        -- organizationrole
        SELECT
            LM.Rahkaran_LetterID,
            O.CorrespondentID AS ReceiverRef,
            CAST(NULL AS NVARCHAR(500)) AS ReceiverTitle
        FROM #TempLetterReceivers TR
        JOIN dbo.Migration_IcanLetter_RahkaranLetter_Map LM
            ON LM.Ican_EntityCode = TR.EntityCode
        JOIN dbo.Migration_IcanOrganizationRole_RahkaranParty_Map O
            ON O.Ican_OrganizationRole_ID = TR.RecipientID  -- <-- rename if different
        WHERE LOWER(TR.RecipientType) = 'organizationrole'
          AND O.CorrespondentID IS NOT NULL
    ),
    Dedup AS
    (
        -- prevent duplicates inside the same batch (same letter + same receiver)
        SELECT DISTINCT
            Rahkaran_LetterID,
            ReceiverRef,
            ReceiverTitle
        FROM R
    ),
    Numbered AS
    (
        SELECT
            *,
            ROW_NUMBER() OVER (ORDER BY Rahkaran_LetterID, ReceiverRef) AS RN
        FROM Dedup
    )
    INSERT INTO #Resolved (Rahkaran_LetterID, ReceiverRef, ReceiverTitle, RN)
    SELECT Rahkaran_LetterID, ReceiverRef, ReceiverTitle, RN
    FROM Numbered;

    -------------------------------------------------------------------------
    -- 4) Insert into {{RAHKARAN_DB}}.ECM.LetterReceiver
    --    Type=1 and [Order]=1 as you requested
    -------------------------------------------------------------------------
    INSERT INTO {{RAHKARAN_DB}}.ECM.LetterReceiver
    (
        LetterReceiverID,
        LetterRef,
        ReceiverRef,
        [Type],
        [Order],
        [Description],
        Creator,
        CreationDate,
        LastModifier,
        LastModificationDate,
        ReceiverTitle
    )
    SELECT
        @LastID + R.RN AS LetterReceiverID,
        R.Rahkaran_LetterID,
        R.ReceiverRef,
        1 AS [Type],
        1 AS [Order],
        NULL AS [Description],
        1 AS Creator,
        GETDATE() AS CreationDate,
        1 AS LastModifier,
        GETDATE() AS LastModificationDate,
        R.ReceiverTitle
    FROM #Resolved R
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM {{RAHKARAN_DB}}.ECM.LetterReceiver LR
        WHERE LR.LetterRef   = R.Rahkaran_LetterID
          AND LR.ReceiverRef = R.ReceiverRef
          AND LR.[Type]      = 1
          AND LR.[Order]     = 1
    );

    DECLARE @InsertedCount BIGINT = @@ROWCOUNT;

    -------------------------------------------------------------------------
    -- 5) Update TableIdGen.LastID
    -------------------------------------------------------------------------
    UPDATE {{RAHKARAN_DB}}.SYS3.TableIdGen
    SET LastID = @LastID + @InsertedCount
    WHERE TableName = 'ECM.LetterReciever';

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

update {{RAHKARAN_DB}}.ECM.letter set LetterType = 3 where LetterID in
(select l.LetterID from {{RAHKARAN_DB}}.ECM.Letter l
inner join
{{RAHKARAN_DB}}.ECM.LetterReceiver lr on lr.LetterRef = l.LetterID
inner join {{RAHKARAN_DB}}.ECM.Correspondent c on c.CorrespondentID = lr.ReceiverRef

where c.[Type] = 7 )

update {{RAHKARAN_DB}}.ECM.letter set LetterType = 2 where LetterType != 3

update {{RAHKARAN_DB}}.SYS3.TableIdGen set LastID = (select max(LetterID)+1 from {{RAHKARAN_DB}}.ECM.Letter)  where TableName = 'ECM.Letter';
