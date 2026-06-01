ALTER TABLE dbo.Migration_UserParty_Map
ADD CorrespondentID BIGINT NULL;

ALTER TABLE dbo.Migration_IcanDepartment_RahkaranParty_Map
ADD CorrespondentID BIGINT NULL;

ALTER TABLE dbo.Migration_IcanOrganizationRole_RahkaranParty_Map
ADD CorrespondentID BIGINT NULL;

ALTER TABLE dbo.Migration_IcanRoles_RahkaranPost_Map
ADD CorrespondentID BIGINT NULL;


UPDATE M
SET CorrespondentID = C.CorrespondentID
FROM dbo.Migration_UserParty_Map M
JOIN {{RAHKARAN_DB}}.ECM.Correspondent C
     ON C.PartyRef = M.Rahkaran_PartyID
    AND C.Type = 1
    AND C.State = 1;

UPDATE M
SET CorrespondentID = C.CorrespondentID
FROM dbo.Migration_IcanOrganizationRole_RahkaranParty_Map M
JOIN {{RAHKARAN_DB}}.ECM.Correspondent C
     ON C.CompanyPartyRef = M.Rahkaran_PartyID
    AND C.Type = 2
    AND C.State = 1;


UPDATE M
SET CorrespondentID = C.CorrespondentID
FROM dbo.Migration_IcanRoles_RahkaranPost_Map M
JOIN {{RAHKARAN_DB}}.ECM.Correspondent C
     ON C.PostRef = M.Rahkaran_PostID
    AND C.Type = 7
    AND C.State = 1;



UPDATE M
SET CorrespondentID = C.CorrespondentID
FROM dbo.Migration_IcanDepartment_RahkaranParty_Map M

JOIN {{RAHKARAN_DB}}.ECM.Correspondent C
     ON C.CompanyPartyRef = m.Rahkaran_PartyID
    AND C.Type = 2
    AND C.State = 1;



