-- Step 0: Ensure the permanent mapping table exists in master
IF OBJECT_ID('master.dbo.Migration_IcanRoles_RahkaranPost_Map', 'U') IS NOT NULL
BEGIN
    DROP TABLE master.dbo.Migration_IcanRoles_RahkaranPost_Map;
END
GO

CREATE TABLE master.dbo.Migration_IcanRoles_RahkaranPost_Map (
    ican_Role_ID INT PRIMARY KEY,
    Rahkaran_PostID BIGINT NOT NULL
);
GO

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO master.dbo.Migration_IcanRoles_RahkaranPost_Map (ican_Role_ID, Rahkaran_PostID)
    SELECT 
        icanRoles.Role_ID, 
        MIN(RahkaranPost.PostID) 
    FROM {{ICAN_DB}}.[dbo].Roles icanRoles
    INNER JOIN {{RAHKARAN_DB}}.HCM3.Post RahkaranPost 
	 ON LTRIM(RTRIM(icanRoles.RoleName)) COLLATE DATABASE_DEFAULT = LTRIM(RTRIM(RahkaranPost.Title)) COLLATE DATABASE_DEFAULT
    WHERE icanRoles.Role_ID NOT IN (SELECT ican_Role_ID FROM master.dbo.Migration_IcanRoles_RahkaranPost_Map)
    GROUP BY icanRoles.Role_ID; 

    IF OBJECT_ID('tempdb..#NewRolesToInsert') IS NOT NULL DROP TABLE #NewRolesToInsert;
    
    SELECT * 
    INTO #NewRolesToInsert
    FROM {{ICAN_DB}}.[dbo].Roles
    WHERE Role_ID NOT IN (SELECT ican_Role_ID FROM master.dbo.Migration_IcanRoles_RahkaranPost_Map);

    DECLARE @RecordCount BIGINT;
    SELECT @RecordCount = COUNT(*) FROM #NewRolesToInsert;

    IF @RecordCount > 0
    BEGIN
        DECLARE @CurrentLastId BIGINT;
        
        SELECT @CurrentLastId = LastId 
        FROM {{RAHKARAN_DB}}.[SYS3].[TableIdGen] WITH (UPDLOCK, ROWLOCK)
        WHERE TableName = 'hcm3.Post';

        IF OBJECT_ID('tempdb..#PreparedRoles') IS NOT NULL DROP TABLE #PreparedRoles;
        
        SELECT 
            Source.Role_ID AS ican_Role_ID,
            @CurrentLastId + ROW_NUMBER() OVER(ORDER BY Source.RoleName) AS Generated_PostID,
            Source.RoleName,
			Source.Title as formalName
        INTO #PreparedRoles
        FROM #NewRolesToInsert AS Source;

        INSERT INTO {{RAHKARAN_DB}}.HCM3.Post(
            PostID,
			Title,
			SecondLanguageTitle,
			Status,
			FormalName,
			Creator,
			CreationDate,
			LastModifier,
			LastModificationDate
        )
        SELECT 
            Generated_PostID,
            RoleName,
            'icanConvert',
            1,
            formalName,
			1,
            GETDATE(),
            1,
            GETDATE() 
        FROM #PreparedRoles;

        UPDATE {{RAHKARAN_DB}}.[SYS3].[TableIdGen]
        SET LastId = @CurrentLastId + @RecordCount
        WHERE TableName = 'hcm3.Post';

        INSERT INTO master.dbo.Migration_IcanRoles_RahkaranPost_Map (ican_Role_ID, Rahkaran_PostID)
        SELECT ican_Role_ID, Generated_PostID
        FROM #PreparedRoles;
    END

    COMMIT TRANSACTION;
    PRINT 'Migration and Mapping completed successfully.';

END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    PRINT 'Error occurred. Transaction rolled back.';
    PRINT ERROR_MESSAGE();
END CATCH