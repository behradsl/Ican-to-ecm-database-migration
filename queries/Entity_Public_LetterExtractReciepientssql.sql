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
    [ican].[dbo].[Entity_public_letter] e
-- Step A: Cast the UDT MultiPersonnelField to NVARCHAR(MAX), then to XML
CROSS APPLY 
    (SELECT CAST(CAST(e.[Receivers] AS NVARCHAR(MAX)) AS XML) AS XmlData) AS CastedData
-- Step B: Call .nodes() on the newly created XML column alias
CROSS APPLY 
    CastedData.XmlData.nodes('/Receivers/Receiver') AS T(c)
WHERE 
    e.[Receivers] IS NOT NULL;

-- 3. Verify the inserted data
SELECT distinct(RecipientType) 
FROM #TempLetterReceivers;

