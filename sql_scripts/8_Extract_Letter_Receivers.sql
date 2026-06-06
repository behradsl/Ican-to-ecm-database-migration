BEGIN TRY
    BEGIN TRANSACTION;

    PRINT 'Step 8: Building Staging Table for Letter Receivers...';

    IF OBJECT_ID('master.dbo.Migration_Staging_LetterReceivers', 'U') IS NOT NULL
        DROP TABLE master.dbo.Migration_Staging_LetterReceivers;

    CREATE TABLE master.dbo.Migration_Staging_LetterReceivers (
        ID BIGINT IDENTITY(1,1) PRIMARY KEY,
        Ican_EntityCode INT NOT NULL,
        RecipientType NVARCHAR(50) NULL,
        RecipientID INT NULL,
        RecipientCaption NVARCHAR(500) NULL,
        LetterRecipientTO NVARCHAR(500) NULL,
        ResolvedCorrespondentID BIGINT NULL
    );

    -- 1. Extract raw data
    INSERT INTO master.dbo.Migration_Staging_LetterReceivers 
        (Ican_EntityCode, RecipientType, RecipientID, RecipientCaption, LetterRecipientTO)
    SELECT 
        e.EntityCode,
        T.c.value('@RecipientType', 'NVARCHAR(50)'),
        T.c.value('@RecipientID', 'INT'),
        T.c.value('@Caption', 'NVARCHAR(500)'),
        LTRIM(RTRIM(e.[To]))
    FROM [{{ICAN_DB}}].[dbo].[Entity_public_letter] e
    CROSS APPLY (SELECT CAST(CAST(e.[Receivers] AS NVARCHAR(MAX)) AS XML) AS XmlData) AS CastedData
    CROSS APPLY CastedData.XmlData.nodes('/Receivers/Receiver') AS T(c)
    WHERE e.[Receivers] IS NOT NULL;

    -- 2. Pre-Map standard Departments
    UPDATE S
    SET ResolvedCorrespondentID = D.CorrespondentID
    FROM master.dbo.Migration_Staging_LetterReceivers S
    JOIN master.dbo.Migration_IcanDepartment_RahkaranParty_Map D ON D.Ican_Department_ID = S.RecipientID
    WHERE LOWER(S.RecipientType) = 'department' AND D.CorrespondentID IS NOT NULL;

    -- 3. Pre-Map standard Roles
    UPDATE S
    SET ResolvedCorrespondentID = P.CorrespondentID
    FROM master.dbo.Migration_Staging_LetterReceivers S
    JOIN master.dbo.Migration_IcanRoles_RahkaranPost_Map P ON P.Ican_Role_ID = S.RecipientID
    WHERE LOWER(S.RecipientType) = 'role' AND P.CorrespondentID IS NOT NULL;

    -- 4. Pre-Map standard OrganizationRoles
    UPDATE S
    SET ResolvedCorrespondentID = O.CorrespondentID
    FROM master.dbo.Migration_Staging_LetterReceivers S
    JOIN master.dbo.Migration_IcanOrganizationRole_RahkaranParty_Map O ON O.Ican_OrganizationRole_ID = S.RecipientID
    WHERE LOWER(S.RecipientType) = 'organizationrole' AND O.CorrespondentID IS NOT NULL;

    -- Clean up empty strings for Step 9
    UPDATE master.dbo.Migration_Staging_LetterReceivers
    SET LetterRecipientTO = NULL
    WHERE LetterRecipientTO = '';

    COMMIT TRANSACTION;
    PRINT 'Step 8 Complete. Data is waiting in master.dbo.Migration_Staging_LetterReceivers.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO