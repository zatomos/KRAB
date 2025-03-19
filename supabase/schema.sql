

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgsodium";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."check_user_in_group"("user_uuid" "uuid", "group_uuid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 
    FROM "Members" 
    WHERE user_id = user_uuid AND group_id = group_uuid
  );
END;
$$;


ALTER FUNCTION "public"."check_user_in_group"("user_uuid" "uuid", "group_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_group"("group_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    new_group_id UUID;
BEGIN
    -- Generate a new UUID for the group
    new_group_id := gen_random_uuid();

    -- Insert the new group using the manually generated UUID
    INSERT INTO "public"."Groups" (id, name)
    VALUES (new_group_id, group_name);

    -- Insert the creator into Members as an admin
    INSERT INTO "public"."Members" (user_id, group_id, admin)
    VALUES (auth.uid(), new_group_id, TRUE);

    -- Return success response
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Group created successfully'
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$;


ALTER FUNCTION "public"."create_group"("group_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_user_profile"("username" "text") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    INSERT INTO "public"."Users" (id, username)
    VALUES ((SELECT auth.uid()), username);
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$;


ALTER FUNCTION "public"."create_user_profile"("username" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_image"("image_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  storage_path TEXT;
BEGIN
  -- Get the storage path
  SELECT storage_path INTO storage_path FROM "Images" WHERE id = image_id;
  
  -- Delete from storage first
  DELETE FROM storage.objects 
  WHERE name = storage_path;
  
  -- Delete from Images table
  DELETE FROM "Images" 
  WHERE id = image_id;
  
  RETURN FOUND;
EXCEPTION WHEN OTHERS THEN
  RETURN FALSE;
END;
$$;


ALTER FUNCTION "public"."delete_image"("image_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_all_images"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_user_id UUID;
  images_data JSONB;
BEGIN
  -- Get the user ID from the current request
  current_user_id := auth.uid();
  
  -- Check if user is authenticated
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not authenticated'
    );
  END IF;
  
  -- Get all images that the user has access to through group membership
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', i.id,
      'uploaded_by', i.uploaded_by,
      'uploaded_at', i.created_at,
      'group_id', ig.group_id
    ) ORDER BY i.created_at DESC
  )
  FROM "Images" i
  JOIN "ImageGroups" ig ON i.id = ig.image_id
  JOIN "Members" m ON ig.group_id = m.group_id
  JOIN auth.users u ON i.uploaded_by = u.id
  WHERE m.user_id = current_user_id
  INTO images_data;
  
  -- Return the complete result
  RETURN jsonb_build_object(
    'success', true,
    'images', COALESCE(images_data, '[]'::jsonb),
    'total_count', (SELECT COUNT(*) FROM (
      SELECT 1
      FROM "Images" i
      JOIN "ImageGroups" ig ON i.id = ig.image_id
      JOIN "Members" m ON ig.group_id = m.group_id
      WHERE m.user_id = current_user_id
    ) AS subquery)
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;


ALTER FUNCTION "public"."get_all_images"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_group_images"("p_group_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  current_user_id UUID;
  images_data JSONB;
  is_member BOOLEAN;
BEGIN
  -- Get the user ID from the current request
  current_user_id := auth.uid();
  
  -- Check if user is authenticated
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not authenticated'
    );
  END IF;
  
  -- Check if user is a member of this group
  SELECT EXISTS (
    SELECT 1 FROM "Members"
    WHERE user_id = current_user_id
      AND group_id = p_group_id
  ) INTO is_member;
  
  IF NOT is_member THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'You are not a member of this group'
    );
  END IF;
  
  -- Get all images for this group, ordering them by created_at descending.
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', i.id,
      'uploaded_by', i.uploaded_by,
      'uploaded_at', i.created_at
    ) ORDER BY i.created_at DESC
  )
  FROM "Images" i
  JOIN "ImageGroups" ig ON i.id = ig.image_id
  JOIN auth.users u ON i.uploaded_by = u.id
  WHERE ig.group_id = p_group_id
  INTO images_data;
  
  -- Return the complete result.
  RETURN jsonb_build_object(
    'success', true,
    'images', COALESCE(images_data, '[]'::jsonb)
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;


ALTER FUNCTION "public"."get_group_images"("p_group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_group_members"("group_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    members JSONB;
BEGIN
    -- Fetch user IDs from Members table and retrieve usernames using get_username function
    SELECT jsonb_agg(
        jsonb_build_object(
            'user_id', m.user_id,
            'username', get_username(m.user_id::text)  -- Call get_username function
        )
    )
    INTO members
    FROM "public"."Members" m
    WHERE m.group_id = get_group_members.group_id;  -- Ensure group_id is referenced correctly

    -- Ensure members is not null (if no members, return empty array)
    IF members IS NULL THEN
        members := '[]'::jsonb;
    END IF;

    -- Return the result
    RETURN jsonb_build_object(
        'success', true,
        'members', members
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$;


ALTER FUNCTION "public"."get_group_members"("group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_image_details"("image_id" "uuid") RETURNS TABLE("created_at" timestamp with time zone, "uploaded_by" "uuid", "description" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY 
  SELECT i.created_at, i.uploaded_by, i.description
  FROM "Images" i
  WHERE i.id = image_id
  AND EXISTS (
    SELECT 1
    FROM "ImageGroups" ig
    JOIN "Members" m ON ig.group_id = m.group_id
    WHERE ig.image_id = i.id
      AND m.user_id = auth.uid() -- Ensures only group members can access
  );
END;
$$;


ALTER FUNCTION "public"."get_image_details"("image_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_latest_image"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_user_id UUID;
  latest_image JSONB;
BEGIN
  -- Get the user ID from the current request
  current_user_id := auth.uid();
  
  -- Check if user is authenticated
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not authenticated'
    );
  END IF;
  
  -- Get the most recent image the user has access to
  SELECT jsonb_build_object(
    'id', i.id,
    'uploaded_by', i.uploaded_by,
    'uploaded_at', i.created_at,
    'group_id', ig.group_id
  )
  FROM "Images" i
  JOIN "ImageGroups" ig ON i.id = ig.image_id
  JOIN "Members" m ON ig.group_id = m.group_id
  WHERE m.user_id = current_user_id
  ORDER BY i.created_at DESC
  LIMIT 1
  INTO latest_image;
  
  -- Return the result
  RETURN jsonb_build_object(
    'success', true,
    'latest_image', COALESCE(latest_image, 'null'::jsonb)
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;


ALTER FUNCTION "public"."get_latest_image"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_groups"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  current_user_id UUID;
  user_groups JSONB;
BEGIN
  -- Get the user ID from the current request
  current_user_id := auth.uid();
  
  -- Check if user is authenticated
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not authenticated'
    );
  END IF;
  
  -- Get all groups the user is a member of with extra information
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', g.id,
      'name', g.name,
      'code', g.code,
      'member_count', (
        SELECT COUNT(*) 
        FROM "Members" 
        WHERE group_id = g.id
      )
    )
  )
  FROM "Groups" g
  JOIN "Members" gm ON g.id = gm.group_id
  WHERE gm.user_id = current_user_id
  INTO user_groups;
  
  RETURN jsonb_build_object(
    'success', true,
    'groups', COALESCE(user_groups, '[]'::jsonb)
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;


ALTER FUNCTION "public"."get_user_groups"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_username"("user_id" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    username TEXT;
BEGIN
    -- Convert user_id (TEXT) to UUID before querying Users
    SELECT u.username INTO username
    FROM "public"."Users" u
    WHERE u.id = user_id::UUID;

    RETURN username;
END;
$$;


ALTER FUNCTION "public"."get_username"("user_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_storage_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Delete the corresponding record from the Images table
  DELETE FROM "Images" 
  WHERE id = (SELECT uuid(REPLACE(OLD.name, '.jpg', '')) FROM regexp_matches(OLD.name, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') AS match);
  
  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."handle_storage_delete"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"("group_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    is_admin BOOLEAN;
BEGIN
    -- Check if the user is an admin of the group
    SELECT admin INTO is_admin
    FROM "public"."Members" m
    WHERE user_id = auth.uid() AND m.group_id = is_admin.group_id;

    -- If no result is found, return FALSE
    RETURN COALESCE(is_admin, FALSE);
END;
$$;


ALTER FUNCTION "public"."is_admin"("group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."join_group_by_code"("group_code" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  current_user_id UUID;
  found_group_id UUID;
  is_already_member BOOLEAN;
BEGIN
  -- Get the user ID from the current request
  current_user_id := auth.uid();
  
  -- Check if user is authenticated
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not authenticated'
    );
  END IF;
  
  -- Find the group by code
  SELECT id INTO found_group_id
  FROM "Groups"
  WHERE code = group_code;
  
  -- Check if group exists
  IF found_group_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Invalid group code'
    );
  END IF;
  
  -- Check if user is already a member
  SELECT EXISTS (
    SELECT 1 FROM "Members"
    WHERE group_id = found_group_id
    AND user_id = current_user_id
  ) INTO is_already_member;
  
  IF is_already_member THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'You are already a member of this group'
    );
  END IF;
  
  -- Add user to the group as a regular member
  INSERT INTO "Members" (group_id, user_id)
  VALUES (found_group_id, current_user_id);
  
  -- Return success
  RETURN jsonb_build_object(
    'success', true,
    'group_id', found_group_id
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;


ALTER FUNCTION "public"."join_group_by_code"("group_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."leave_group"("group_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    deleted_count INT;
    user_check UUID;
BEGIN
    -- Check if the user exists in the group before deletion
    SELECT user_id INTO user_check
    FROM "public"."Members" m
    WHERE user_id = auth.uid()
    AND m.group_id = leave_group.group_id;

    -- If user does not exist, return an error
    IF user_check IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'User is not a member of this group or has no permission'
        );
    END IF;

    -- Perform the deletion
    DELETE FROM "public"."Members" m
    WHERE user_id = auth.uid()
    AND m.group_id = leave_group.group_id
    RETURNING 1 INTO deleted_count;

    -- If no rows were deleted, return an error
    IF deleted_count IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Failed to remove user from group'
        );
    END IF;

    -- Return success message
    RETURN jsonb_build_object(
        'success', true,
        'message', 'You have successfully left the group'
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$;


ALTER FUNCTION "public"."leave_group"("group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_group"("group_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    is_admin BOOLEAN;
BEGIN
    -- Check if the user is an admin of the group
    SELECT admin INTO is_admin
    FROM "public"."Members" m
    WHERE user_id = auth.uid() AND m.group_id = remove_group.group_id;

    -- If the user is not an admin, deny deletion
    IF is_admin IS NULL OR is_admin = FALSE THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only admins can delete the group'
        );
    END IF;

    -- Remove all members from the group
    DELETE FROM "public"."Members" m
    WHERE m.group_id = remove_group.group_id;

    -- Delete the group
    DELETE FROM "public"."Groups"
    WHERE id = remove_group.group_id;

    -- Return success response
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Group removed successfully'
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$;


ALTER FUNCTION "public"."remove_group"("group_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_group_name"("group_id" "uuid", "new_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  current_user_id UUID;
BEGIN
  -- Get the user ID from the current request
  current_user_id := auth.uid();

  -- Check if user is authenticated
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not authenticated'
    );
  END IF;

  -- Check if the user is a member of the group
  IF NOT EXISTS (
    SELECT 1 FROM "Members" m
    WHERE user_id = current_user_id
    AND m.group_id = update_group_name.group_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Only group members can update the group name'
    );
  END IF;

  -- Update the group name
  UPDATE "Groups"
  SET name = new_name
  WHERE id = update_group_name.group_id;

  -- Return success response
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Group name updated successfully'
  );

EXCEPTION 
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."update_group_name"("group_id" "uuid", "new_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upload_image_to_groups"("group_ids" "uuid"[], "image_description" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$DECLARE
  current_user_id UUID;
  image_id UUID;
  authorized_count INTEGER;
BEGIN
  current_user_id := auth.uid();
  
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not authenticated'
    );
  END IF;
  
  image_id := uuid_generate_v4();
  
  INSERT INTO "Images" (id, uploaded_by, description)
  VALUES (image_id, current_user_id, image_description);
  
  -- Insert all associations in one go
  WITH inserted AS (
    INSERT INTO "ImageGroups" (image_id, group_id)
    SELECT image_id, g
    FROM unnest(group_ids) AS g
    WHERE EXISTS (
      SELECT 1 
      FROM "Members" m
      WHERE m.user_id = current_user_id
        AND m.group_id = g
    )
    RETURNING 1
  )
  SELECT count(*) INTO authorized_count FROM inserted;
  
  RETURN jsonb_build_object(
    'success', true,
    'image_id', image_id,
    'authorized_groups', authorized_count
  );
  
EXCEPTION 
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;$$;


ALTER FUNCTION "public"."upload_image_to_groups"("group_ids" "uuid"[], "image_description" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."Groups" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" DEFAULT 'My new group'::"text" NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(4), 'hex'::"text") NOT NULL,
    CONSTRAINT "Groups_name_check" CHECK (("length"("name") < 20)),
    CONSTRAINT "check_group_name_length" CHECK ((("length"("name") > 2) AND ("length"("name") < 20)))
);


ALTER TABLE "public"."Groups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ImageGroups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "image_id" "uuid" NOT NULL,
    "group_id" "uuid" DEFAULT "gen_random_uuid"()
);


ALTER TABLE "public"."ImageGroups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Images" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "uploaded_by" "uuid" NOT NULL,
    "description" "text",
    CONSTRAINT "Images_description_check" CHECK (("length"("description") < 200))
);


ALTER TABLE "public"."Images" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Members" (
    "user_id" "uuid" NOT NULL,
    "group_id" "uuid" NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admin" boolean DEFAULT false NOT NULL,
    CONSTRAINT "Members_admin_check" CHECK (("admin" = ANY (ARRAY[true, false])))
);


ALTER TABLE "public"."Members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Users" (
    "username" "text" DEFAULT ''::"text",
    "id" "uuid" NOT NULL,
    "fcm_token" "text",
    CONSTRAINT "Users_username_check" CHECK (("length"("username") < 20))
);


ALTER TABLE "public"."Users" OWNER TO "postgres";


COMMENT ON TABLE "public"."Users" IS 'contains usernames';



ALTER TABLE ONLY "public"."Groups"
    ADD CONSTRAINT "Groups_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."Groups"
    ADD CONSTRAINT "Groups_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."Groups"
    ADD CONSTRAINT "Groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ImageGroups"
    ADD CONSTRAINT "ImageGroups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."Images"
    ADD CONSTRAINT "Images_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."Members"
    ADD CONSTRAINT "Members_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."Members"
    ADD CONSTRAINT "Members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."Users"
    ADD CONSTRAINT "Users_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."Users"
    ADD CONSTRAINT "Users_pkey" PRIMARY KEY ("id");



CREATE OR REPLACE TRIGGER "on-image-insert" AFTER INSERT ON "public"."ImageGroups" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://your_url.supabase.co/functions/v1/new_image_notify', 'POST', '{"Content-type":"application/json"}', '{}', '5000');



ALTER TABLE ONLY "public"."ImageGroups"
    ADD CONSTRAINT "ImageGroups_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."Groups"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ImageGroups"
    ADD CONSTRAINT "ImageGroups_image_id_fkey" FOREIGN KEY ("image_id") REFERENCES "public"."Images"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."Images"
    ADD CONSTRAINT "Images_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."Members"
    ADD CONSTRAINT "Members_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."Groups"("id");



ALTER TABLE ONLY "public"."Members"
    ADD CONSTRAINT "Members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."Users"
    ADD CONSTRAINT "Users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;



CREATE POLICY "Admins can update the group name" ON "public"."Groups" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."Members"
  WHERE (("Members"."group_id" = "Groups"."id") AND ("Members"."user_id" = "auth"."uid"()) AND ("Members"."admin" = true)))));



CREATE POLICY "Allow admins to delete a group" ON "public"."Groups" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."Members"
  WHERE (("Members"."group_id" = "Groups"."id") AND ("Members"."user_id" = "auth"."uid"()) AND ("Members"."admin" = true)))));



CREATE POLICY "Allow users to create groups" ON "public"."Groups" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Enable delete for users based on user_id" ON "public"."Members" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Enable insert for authenticated users only" ON "public"."ImageGroups" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."Images" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for users" ON "public"."Users" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id"));



CREATE POLICY "Enable insert for users based on user_id" ON "public"."Members" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Enable select for users" ON "public"."Users" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id"));



CREATE POLICY "Enable update for users based on user_id" ON "public"."Users" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id"));



CREATE POLICY "Group members can access images of their groups" ON "public"."Images" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."ImageGroups" "ig"
     JOIN "public"."Members" "m" ON (("ig"."group_id" = "m"."group_id")))
  WHERE (("ig"."image_id" = "Images"."id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Group members can see their groups" ON "public"."Groups" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."Members" "m"
  WHERE (("m"."group_id" = "Groups"."id") AND ("m"."user_id" = "auth"."uid"())))));



CREATE POLICY "Group members can select images from that group" ON "public"."ImageGroups" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."Members" "m"
  WHERE (("m"."group_id" = "ImageGroups"."group_id") AND ("m"."user_id" = "auth"."uid"())))));



ALTER TABLE "public"."Groups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ImageGroups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Images" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "Users can see members of groups they belong to" ON "public"."Members" FOR SELECT USING ("public"."check_user_in_group"("auth"."uid"(), "group_id"));



CREATE POLICY "Users can see members of their groups" ON "public"."Users" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."Members" "m1"
     JOIN "public"."Members" "m2" ON (("m1"."group_id" = "m2"."group_id")))
  WHERE (("m1"."user_id" = "auth"."uid"()) AND ("m2"."user_id" = "Users"."id")))));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";




















































































































































































GRANT ALL ON FUNCTION "public"."check_user_in_group"("user_uuid" "uuid", "group_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."check_user_in_group"("user_uuid" "uuid", "group_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_user_in_group"("user_uuid" "uuid", "group_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_group"("group_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_group"("group_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_group"("group_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_user_profile"("username" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_user_profile"("username" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_user_profile"("username" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_image"("image_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_image"("image_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_image"("image_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_all_images"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_all_images"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_all_images"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_group_images"("p_group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_group_images"("p_group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_group_images"("p_group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_group_members"("group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_group_members"("group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_group_members"("group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_image_details"("image_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_image_details"("image_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_image_details"("image_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_latest_image"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_latest_image"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_latest_image"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_groups"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_groups"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_groups"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_username"("user_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_username"("user_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_username"("user_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_storage_delete"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_storage_delete"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_storage_delete"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"("group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"("group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"("group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."join_group_by_code"("group_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."join_group_by_code"("group_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."join_group_by_code"("group_code" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."leave_group"("group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."leave_group"("group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."leave_group"("group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."remove_group"("group_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."remove_group"("group_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_group"("group_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_group_name"("group_id" "uuid", "new_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_group_name"("group_id" "uuid", "new_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_group_name"("group_id" "uuid", "new_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."upload_image_to_groups"("group_ids" "uuid"[], "image_description" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."upload_image_to_groups"("group_ids" "uuid"[], "image_description" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upload_image_to_groups"("group_ids" "uuid"[], "image_description" "text") TO "service_role";


















GRANT ALL ON TABLE "public"."Groups" TO "anon";
GRANT ALL ON TABLE "public"."Groups" TO "authenticated";
GRANT ALL ON TABLE "public"."Groups" TO "service_role";



GRANT ALL ON TABLE "public"."ImageGroups" TO "anon";
GRANT ALL ON TABLE "public"."ImageGroups" TO "authenticated";
GRANT ALL ON TABLE "public"."ImageGroups" TO "service_role";



GRANT ALL ON TABLE "public"."Images" TO "anon";
GRANT ALL ON TABLE "public"."Images" TO "authenticated";
GRANT ALL ON TABLE "public"."Images" TO "service_role";



GRANT ALL ON TABLE "public"."Members" TO "anon";
GRANT ALL ON TABLE "public"."Members" TO "authenticated";
GRANT ALL ON TABLE "public"."Members" TO "service_role";



GRANT ALL ON TABLE "public"."Users" TO "anon";
GRANT ALL ON TABLE "public"."Users" TO "authenticated";
GRANT ALL ON TABLE "public"."Users" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";






























RESET ALL;
