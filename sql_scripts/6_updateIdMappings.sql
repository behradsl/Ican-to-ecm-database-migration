-- 1. Add CorrespondentID to UserParty_Map if it doesn't exist
IF NOT EXISTS (
    SELECT * FROM master.sys.columns  -- <--- FIXED: Explicitly query master.sys.columns
    WHERE object_id = OBJECT_ID('master.dbo.Migration_UserParty_Map') 
    AND name = 'CorrespondentID'
)
BEGIN
    ALTER TABLE master.dbo.Migration_UserParty_Map
    ADD CorrespondentID BIGINT NULL;
END
GO

-- 2. Add CorrespondentID to IcanDepartment_RahkaranParty_Map if it doesn't exist
IF NOT EXISTS (
    SELECT * FROM master.sys.columns 
    WHERE object_id = OBJECT_ID('master.dbo.Migration_IcanDepartment_RahkaranParty_Map') 
    AND name = 'CorrespondentID'
)
BEGIN
    ALTER TABLE master.dbo.Migration_IcanDepartment_RahkaranParty_Map
    ADD CorrespondentID BIGINT NULL;
END
GO

-- 3. Add CorrespondentID to IcanOrganizationRole_RahkaranParty_Map if it doesn't exist
IF NOT EXISTS (
    SELECT * FROM master.sys.columns 
    WHERE object_id = OBJECT_ID('master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map') 
    AND name = 'CorrespondentID'
)
BEGIN
    ALTER TABLE master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map
    ADD CorrespondentID BIGINT NULL;
END
GO

-- 4. Add CorrespondentID to IcanRoles_RahkaranPost_Map if it doesn't exist
IF NOT EXISTS (
    SELECT * FROM master.sys.columns 
    WHERE object_id = OBJECT_ID('master.dbo.Migration_IcanRoles_RahkaranPost_Map') 
    AND name = 'CorrespondentID'
)
BEGIN
    ALTER TABLE master.dbo.Migration_IcanRoles_RahkaranPost_Map
    ADD CorrespondentID BIGINT NULL;
END
GO

-- Now that all columns are guaranteed to exist, perform the updates
UPDATE M
SET CorrespondentID = C.CorrespondentID
FROM master.dbo.Migration_UserParty_Map M
JOIN {{RAHKARAN_DB}}.ECM.Correspondent C
     ON C.PartyRef = M.Rahkaran_PartyID
    AND C.Type = 1
    AND C.State = 1;
GO

UPDATE M
SET CorrespondentID = C.CorrespondentID
FROM master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map M
JOIN {{RAHKARAN_DB}}.ECM.Correspondent C
     ON C.CompanyPartyRef = M.Rahkaran_PartyID
    AND C.Type = 2
    AND C.State = 1;
GO

UPDATE M
SET CorrespondentID = C.CorrespondentID
FROM master.dbo.Migration_IcanRoles_RahkaranPost_Map M
JOIN {{RAHKARAN_DB}}.ECM.Correspondent C
     ON C.PostRef = M.Rahkaran_PostID
    AND C.Type = 7
    AND C.State = 1;
GO

UPDATE M
SET CorrespondentID = C.CorrespondentID
FROM master.dbo.Migration_IcanDepartment_RahkaranParty_Map M
JOIN {{RAHKARAN_DB}}.ECM.Correspondent C
     ON C.CompanyPartyRef = M.Rahkaran_PartyID
    AND C.Type = 2
    AND C.State = 1;
GO