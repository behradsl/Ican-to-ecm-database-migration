-- Step 0: Ensure the permanent mapping table exists


IF OBJECT_ID('Migration_IcanRoles_RahkaranPost', 'U') IS NULL
BEGIN
    CREATE TABLE Migration_IcanRoles_RahkaranPost_Map (
        ican_Role_ID INT PRIMARY KEY,
        Rahkaran_PostID BIGINT NOT NULL
    );
END

BEGIN TRY
    BEGIN TRANSACTION;

    -- =====================================================================
    -- PHASE 1: MATCH EXISTING RECORDS
    -- =====================================================================
    
    INSERT INTO Migration_IcanRoles_RahkaranPost_Map (ican_Role_ID, Rahkaran_PostID)
    SELECT 
        icanRoles.Role_ID, 
        MIN(RahkaranPost.PostID) 
    FROM ican.[dbo].Roles icanRoles
    INNER JOIN RahkaranSg.HCM3.Post RahkaranPost 
	 ON LTRIM(RTRIM(icanRoles.RoleName)) COLLATE DATABASE_DEFAULT = LTRIM(RTRIM(RahkaranPost.Title)) COLLATE DATABASE_DEFAULT
    WHERE icanRoles.Role_ID NOT IN (SELECT ican_Role_ID FROM Migration_IcanRoles_RahkaranPost_Map)
    GROUP BY icanRoles.Role_ID; 

    -- =====================================================================
    -- PHASE 2: INSERT NEW RECORDS
    -- =====================================================================

    -- 1. Rename temp table to avoid session caching issues from previous scripts
    IF OBJECT_ID('tempdb..#NewRolesToInsert') IS NOT NULL DROP TABLE #NewRolesToInsert;
    
    SELECT * 
    INTO #NewRolesToInsert
    FROM ican.[dbo].Roles
    WHERE Role_ID NOT IN (SELECT ican_Role_ID FROM Migration_IcanRoles_RahkaranPost_Map);

    DECLARE @RecordCount BIGINT;
    SELECT @RecordCount = COUNT(*) FROM #NewRolesToInsert;

    IF @RecordCount > 0
    BEGIN
        DECLARE @CurrentLastId BIGINT;
        
        SELECT @CurrentLastId = LastId 
        FROM RahkaranSg.[SYS3].[TableIdGen] WITH (UPDLOCK, ROWLOCK)
        WHERE TableName = 'hcm3.Post';

        -- 2. Unique temp table name for prepared data
        IF OBJECT_ID('tempdb..#PreparedRoles') IS NOT NULL DROP TABLE #PreparedRoles;
        
        SELECT 
            Source.Role_ID AS ican_Role_ID,
            -- 3. Fixed typo: DepartmentID (no underscore) based on icanSchema.sql
            @CurrentLastId + ROW_NUMBER() OVER(ORDER BY Source.RoleName) AS Generated_PostID,
            Source.RoleName,
			Source.Title as formalName
        INTO #PreparedRoles
        FROM #NewRolesToInsert AS Source;

        -- Insert into Rahkaran Party Table
        INSERT INTO RahkaranSg.HCM3.Post(
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

        -- Update the TableIdGen with the new maximum ID
        UPDATE RahkaranSg.[SYS3].[TableIdGen]
        SET LastId = @CurrentLastId + @RecordCount
        WHERE TableName = 'gnr3.party';

        -- Save the NEW relations into our permanent mapping table
        INSERT INTO Migration_IcanRoles_RahkaranPost_Map (ican_Role_ID, Rahkaran_PostID)
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
