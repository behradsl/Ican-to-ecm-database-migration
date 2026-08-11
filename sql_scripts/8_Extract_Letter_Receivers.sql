BEGIN TRY
    BEGIN TRANSACTION;

    PRINT 'Step 8: Rebuilding Staging Table for Letter Receivers (safe to re-run)...';

    -- Staging is ephemeral and rebuilt each run; permanent maps are left intact.
    IF OBJECT_ID('master.dbo.Migration_Staging_LetterReceivers', 'U') IS NOT NULL
        DROP TABLE master.dbo.Migration_Staging_LetterReceivers;

    CREATE TABLE master.dbo.Migration_Staging_LetterReceivers (
        ID BIGINT IDENTITY(1,1) PRIMARY KEY,
        Ican_EntityCode INT NOT NULL,
        RecipientType NVARCHAR(50) NULL,
        RecipientID INT NULL,
        RecipientCaption NVARCHAR(MAX) NULL,
        LetterRecipientTO NVARCHAR(MAX) NULL,
        -- Normalized name used to create/match Party for free-text / unresolved rows
        ResolvePartyName NVARCHAR(100) NULL,
        ResolvedCorrespondentID BIGINT NULL
    );

    COMMIT TRANSACTION;
    PRINT 'Staging table created.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

BEGIN TRY
    BEGIN TRANSACTION;

    -- 1. Extract raw data
    INSERT INTO master.dbo.Migration_Staging_LetterReceivers 
        (Ican_EntityCode, RecipientType, RecipientID, RecipientCaption, LetterRecipientTO)
    SELECT 
        e.EntityCode,
        T.c.value('@RecipientType', 'NVARCHAR(50)'),
        T.c.value('@RecipientID', 'INT'),
        T.c.value('@Caption', 'NVARCHAR(MAX)'),
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

    -- Clean up empty strings
    UPDATE master.dbo.Migration_Staging_LetterReceivers
    SET LetterRecipientTO = NULL
    WHERE LetterRecipientTO = '';

    UPDATE master.dbo.Migration_Staging_LetterReceivers
    SET RecipientCaption = NULL
    WHERE LTRIM(RTRIM(ISNULL(RecipientCaption, N''))) = N'';

    -- 5. Build ResolvePartyName for unresolved rows (free-text -1/'' and any other unresolved)
    -- Prefer Caption first line (before <br/>); fall back to letter To.
    UPDATE S
    SET ResolvePartyName = LEFT(cleaned.NameText, 100)
    FROM master.dbo.Migration_Staging_LetterReceivers S
    CROSS APPLY (
        SELECT LTRIM(RTRIM(
            REPLACE(REPLACE(REPLACE(REPLACE(
                CASE
                    WHEN S.RecipientCaption IS NOT NULL THEN
                        CASE
                            WHEN CHARINDEX(N'<br', LOWER(S.RecipientCaption)) > 0
                                THEN LEFT(S.RecipientCaption, CHARINDEX(N'<br', LOWER(S.RecipientCaption)) - 1)
                            WHEN CHARINDEX(N'&lt;br', LOWER(S.RecipientCaption)) > 0
                                THEN LEFT(S.RecipientCaption, CHARINDEX(N'&lt;br', LOWER(S.RecipientCaption)) - 1)
                            ELSE S.RecipientCaption
                        END
                    ELSE S.LetterRecipientTO
                END,
                NCHAR(13), N' '), NCHAR(10), N' '), N'  ', N' '), N'  ', N' ')
        )) AS NameText
    ) cleaned
    WHERE S.ResolvedCorrespondentID IS NULL
      AND cleaned.NameText IS NOT NULL
      AND cleaned.NameText <> N'';

    DECLARE @FreeTextCount INT;
    SELECT @FreeTextCount = COUNT(*)
    FROM master.dbo.Migration_Staging_LetterReceivers
    WHERE ResolvedCorrespondentID IS NULL AND ResolvePartyName IS NOT NULL;

    COMMIT TRANSACTION;
    PRINT 'Step 8 Complete. Unresolved rows with ResolvePartyName: '
        + CAST(ISNULL(@FreeTextCount, 0) AS VARCHAR);
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
