--
-- PostgreSQL database dump
--

-- Dumped from database version 15.8
-- Dumped by pg_dump version 15.8

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

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: add_comment(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_comment(group_id uuid, image_id uuid, text text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
DECLARE
    current_user_id UUID;
BEGIN
    current_user_id := auth.uid();

    -- Check if user is authenticated
    IF current_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'User not authenticated'
        );
    END IF;

    -- Validate that the user is a member of the group
    IF NOT EXISTS (
        SELECT 1
        FROM "Members" m
        WHERE m.user_id = current_user_id
          AND m.group_id = add_comment.group_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'You are not a member of this group'
        );
    END IF;

    -- Validate that the image belongs to the specified group
    IF NOT EXISTS (
        SELECT 1
        FROM "ImageGroups" ig
        WHERE ig.image_id = add_comment.image_id
          AND ig.group_id = add_comment.group_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Image does not belong to the specified group'
        );
    END IF;

    -- Insert comment
    INSERT INTO "public"."Comments" (user_id, image_id, group_id, text)
    VALUES (current_user_id, add_comment.image_id, add_comment.group_id, add_comment.text);

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Comment added successfully'
    );
EXCEPTION
    WHEN UNIQUE_VIOLATION THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'You have already commented on this image'
        );
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$;


--
-- Name: call_get_group_members_count(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.call_get_group_members_count(p_group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
BEGIN
  RETURN public.get_group_members_count('1df209bc-6c5b-4624-8f88-d69fdf12f3d6');
END;
$$;


--
-- Name: check_user_in_group(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_user_in_group(user_uuid uuid, group_uuid uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM "Members"
    WHERE user_id = user_uuid AND group_id = group_uuid
  );
END;
$$;


--
-- Name: create_group(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_group(group_name text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
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
END;$$;


--
-- Name: create_user_profile(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_user_profile(username text) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
BEGIN
    INSERT INTO "public"."Users" (id, username)
    VALUES ((SELECT auth.uid()), username);
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$;


--
-- Name: delete_comment(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_comment(group_id uuid, image_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
    current_user_id UUID;
BEGIN
    current_user_id := auth.uid();

    -- Check if user is authenticated
    IF current_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'User not authenticated'
        );
    END IF;

    -- Validate that the user is a member of the group
    IF NOT EXISTS (
        SELECT 1
        FROM "Members" m
        WHERE m.user_id = current_user_id
          AND m.group_id = delete_comment.group_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'You are not a member of this group'
        );
    END IF;

    -- Validate that the image belongs to the specified group
    IF NOT EXISTS (
        SELECT 1
        FROM "ImageGroups" ig
        WHERE ig.image_id = delete_comment.image_id
          AND ig.group_id = delete_comment.group_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Image does not belong to the specified group'
        );
    END IF;

    -- Delete the comment if it belongs to the current user
    DELETE FROM "Comments" c
    WHERE c.image_id = delete_comment.image_id
      AND c.group_id = delete_comment.group_id
      AND c.user_id = current_user_id;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Comment deleted successfully'
        );
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'error', 'No comment found to delete or permission denied'
        );
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;$$;


--
-- Name: delete_image(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_image(image_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
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
END;$$;


--
-- Name: get_all_images(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_all_images() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
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
END;$$;


--
-- Name: get_comment_count(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_comment_count(group_id uuid, image_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
DECLARE
    current_user_id UUID;
    comment_count INTEGER;
BEGIN
    current_user_id := auth.uid();

    -- Check if user is authenticated
    IF current_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'User not authenticated'
        );
    END IF;

    -- Validate that the user is a member of the group
    IF NOT EXISTS (
        SELECT 1 FROM "Members" m
        WHERE m.user_id = current_user_id
          AND m.group_id = get_comment_count.group_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'You are not a member of this group'
        );
    END IF;

    -- Validate that the image belongs to the specified group
    IF NOT EXISTS (
        SELECT 1 FROM "ImageGroups" ig
        WHERE ig.image_id = get_comment_count.image_id
          AND ig.group_id = get_comment_count.group_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Image does not belong to the specified group'
        );
    END IF;

    -- Count comments for the image in the specified group
    SELECT COUNT(*) INTO comment_count
    FROM "Comments" c
    WHERE c.image_id = get_comment_count.image_id
      AND c.group_id = get_comment_count.group_id;

    RETURN jsonb_build_object(
        'success', true,
        'count', comment_count
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$;


--
-- Name: get_comments(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_comments(group_id uuid, image_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
DECLARE
    current_user_id UUID;
    comments JSONB;
BEGIN
    current_user_id := auth.uid();

    -- Check if user is authenticated
    IF current_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'User not authenticated'
        );
    END IF;

    -- Validate that the user is a member of the group
    IF NOT EXISTS (
        SELECT 1
        FROM "Members" AS m
        WHERE m.user_id = current_user_id
          AND m.group_id = get_comments.group_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'You are not a member of this group'
        );
    END IF;

    -- Validate that the image belongs to the specified group
    IF NOT EXISTS (
        SELECT 1
        FROM "ImageGroups" AS ig
        WHERE ig.image_id = get_comments.image_id
          AND ig.group_id = get_comments.group_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Image does not belong to the specified group'
        );
    END IF;

    -- Retrieve comments for the image in the specified group
    SELECT jsonb_agg(comment_obj) INTO comments
    FROM (
        SELECT
            c.user_id,
            c.text,
            c.created_at
        FROM "Comments" AS c
        WHERE c.image_id = get_comments.image_id
          AND c.group_id = get_comments.group_id
        ORDER BY c.created_at DESC
    ) AS comment_obj;

    RETURN jsonb_build_object(
        'success', true,
        'comments', comments
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$;


--
-- Name: get_group_details(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_group_details(group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
DECLARE
    group_record RECORD;
BEGIN
    SELECT id, created_at, name, code
    INTO group_record
    FROM "Groups"
    WHERE id = get_group_details.group_id;

    IF group_record IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Group not found');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'group', jsonb_build_object(
            'id', group_record.id,
            'created_at', group_record.created_at,
            'name', group_record.name,
            'code', group_record.code
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


--
-- Name: get_group_images(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_group_images(p_group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
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
END;$$;


--
-- Name: get_group_members(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_group_members(group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
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
END;$$;


--
-- Name: get_group_members_count(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_group_members_count(group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
    member_count INTEGER;
    group_exists BOOLEAN;
BEGIN
    -- Check if the group exists
    SELECT EXISTS(SELECT 1 FROM "Groups" g WHERE g.id = get_group_members_count.group_id)
    INTO group_exists;

    -- If group doesn't exist, return error
    IF NOT group_exists THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Group not found'
        );
    END IF;

    -- Count members in the group
    SELECT COUNT(*)
    INTO member_count
    FROM "Members" m
    WHERE m.group_id = get_group_members_count.group_id;

    -- Return results
    RETURN jsonb_build_object(
        'success', true,
        'group_id', get_group_members_count.group_id,
        'member_count', member_count
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;$$;


--
-- Name: get_image_details(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_image_details(image_id uuid) RETURNS TABLE(created_at timestamp with time zone, uploaded_by uuid, description text)
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
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


--
-- Name: get_latest_image(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_latest_image() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
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
  -- Handle any errors
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;


--
-- Name: get_user_groups(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_groups() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
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

  -- Get all groups the user is a member of
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', g.id,
      'name', g.name,
      'code', g.code,
      'created_at', g.created_at
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
END;$$;


--
-- Name: get_username(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_username(user_id text) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
    username TEXT;
BEGIN
    -- Convert user_id (TEXT) to UUID before querying Users
    SELECT u.username INTO username
    FROM "public"."Users" u
    WHERE u.id = user_id::UUID;

    RETURN username;
END;$$;


--
-- Name: handle_storage_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_storage_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
BEGIN
  -- Delete the corresponding record from the Images table
  DELETE FROM "Images"
  WHERE id = (SELECT uuid(REPLACE(OLD.name, '.jpg', '')) FROM regexp_matches(OLD.name, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') AS match);

  RETURN OLD;
END;
$$;


--
-- Name: is_admin(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin(group_id uuid) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
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


--
-- Name: join_group_by_code(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.join_group_by_code(group_code text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
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
END;$$;


--
-- Name: leave_group(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.leave_group(group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
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
END;$$;


--
-- Name: register_uploaded_image(uuid, text[], text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_uploaded_image(image_id uuid, group_ids text[], image_description text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  current_user_id uuid;
  authorized_count integer := 0;
begin
  current_user_id := auth.uid();
  if current_user_id is null then
    return jsonb_build_object('success', false, 'error', 'User not authenticated');
  end if;

  -- Insert/ensure image metadata
  insert into "Images" (id, uploaded_by, description)
  values (register_uploaded_image.image_id, current_user_id, register_uploaded_image.image_description)
  on conflict (id) do nothing;

  -- Insert all authorized group links
  with inserted as (
    insert into "ImageGroups" (image_id, group_id)
    select register_uploaded_image.image_id, (g)::uuid
    from unnest(register_uploaded_image.group_ids) as g
    where exists (
      select 1
      from "Members" m
      where m.user_id = current_user_id
        and m.group_id = (g)::uuid
    )
    on conflict do nothing
    returning 1
  )
  select count(*) into authorized_count from inserted;

  return jsonb_build_object(
    'success', true,
    'image_id', register_uploaded_image.image_id,
    'authorized_groups', authorized_count
  );

exception
  when others then
    return jsonb_build_object('success', false, 'error', sqlerrm);
end;
$$;


--
-- Name: remove_group(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.remove_group(group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
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
END;$$;


--
-- Name: request_image_uuid(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.request_image_uuid() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  current_user_id uuid;
  new_id uuid;
begin
  current_user_id := auth.uid();
  if current_user_id is null then
    return jsonb_build_object('success', false, 'error', 'User not authenticated');
  end if;
  new_id := gen_random_uuid();

  return jsonb_build_object('success', true, 'image_id', new_id);
exception
  when others then
    return jsonb_build_object('success', false, 'error', sqlerrm);
end;
$$;


--
-- Name: update_comment(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_comment(group_id uuid, image_id uuid, text text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
    current_user_id UUID;
BEGIN
    current_user_id := auth.uid();

    -- Check if user is authenticated
    IF current_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'User not authenticated'
        );
    END IF;

    -- Validate that the user is a member of the group
    IF NOT EXISTS (
        SELECT 1
        FROM "Members" m
        WHERE m.user_id = current_user_id
          AND m.group_id = update_comment.group_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'You are not a member of this group'
        );
    END IF;

    -- Validate that the image belongs to the specified group
    IF NOT EXISTS (
        SELECT 1
        FROM "ImageGroups" ig
        WHERE ig.image_id = update_comment.image_id
          AND ig.group_id = update_comment.group_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Image does not belong to the specified group'
        );
    END IF;

    -- Update the comment if it belongs to the current user
    UPDATE "Comments" c
    SET text = update_comment.text
    WHERE c.image_id = update_comment.image_id
      AND c.group_id = update_comment.group_id
      AND c.user_id = current_user_id;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Comment updated successfully'
        );
    ELSE
        RETURN jsonb_build_object(
            'success', false,
            'error', 'No comment found to update or permission denied'
        );
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;$$;


--
-- Name: update_group_name(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_group_name(group_id uuid, new_name text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$DECLARE
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
END;$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: Comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Comments" (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid NOT NULL,
    image_id uuid NOT NULL,
    text text,
    group_id uuid NOT NULL,
    CONSTRAINT "Comments_text_check" CHECK ((length(text) < 200))
);


--
-- Name: TABLE "Comments"; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public."Comments" IS 'Comments left by users about an image';


--
-- Name: Groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Groups" (
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    name text DEFAULT 'My new group'::text NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text DEFAULT encode(extensions.gen_random_bytes(4), 'hex'::text) NOT NULL,
    CONSTRAINT "Groups_name_check" CHECK ((length(name) < 20)),
    CONSTRAINT check_group_name_length CHECK (((length(name) > 2) AND (length(name) < 20)))
);


--
-- Name: ImageGroups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."ImageGroups" (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    image_id uuid NOT NULL,
    group_id uuid DEFAULT gen_random_uuid()
);


--
-- Name: Images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Images" (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    uploaded_by uuid NOT NULL,
    description text,
    CONSTRAINT "Images_description_check" CHECK ((length(description) < 200))
);


--
-- Name: Members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Members" (
    user_id uuid NOT NULL,
    group_id uuid NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    admin boolean DEFAULT false NOT NULL,
    CONSTRAINT "Members_admin_check" CHECK ((admin = ANY (ARRAY[true, false])))
);


--
-- Name: Users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Users" (
    username text DEFAULT ''::text,
    id uuid NOT NULL,
    fcm_token text,
    CONSTRAINT "Users_username_check" CHECK ((length(username) < 20))
);


--
-- Name: TABLE "Users"; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public."Users" IS 'contains usernames';


--
-- Name: Comments Comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Comments"
    ADD CONSTRAINT "Comments_pkey" PRIMARY KEY (id);


--
-- Name: Groups Groups_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Groups"
    ADD CONSTRAINT "Groups_code_key" UNIQUE (code);


--
-- Name: Groups Groups_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Groups"
    ADD CONSTRAINT "Groups_id_key" UNIQUE (id);


--
-- Name: Groups Groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Groups"
    ADD CONSTRAINT "Groups_pkey" PRIMARY KEY (id);


--
-- Name: ImageGroups ImageGroups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."ImageGroups"
    ADD CONSTRAINT "ImageGroups_pkey" PRIMARY KEY (id);


--
-- Name: Images Images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Images"
    ADD CONSTRAINT "Images_pkey" PRIMARY KEY (id);


--
-- Name: Members Members_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Members"
    ADD CONSTRAINT "Members_id_key" UNIQUE (id);


--
-- Name: Members Members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Members"
    ADD CONSTRAINT "Members_pkey" PRIMARY KEY (id);


--
-- Name: Users Users_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Users"
    ADD CONSTRAINT "Users_id_key" UNIQUE (id);


--
-- Name: Users Users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Users"
    ADD CONSTRAINT "Users_pkey" PRIMARY KEY (id);


--
-- Name: Comments unique_user_image_comment; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Comments"
    ADD CONSTRAINT unique_user_image_comment UNIQUE (user_id, image_id);


--
-- Name: Comments on-comment-insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER "on-comment-insert" AFTER INSERT ON public."Comments" FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('your_supabase_url/functions/v1/comment-notification', 'POST', '{"Content-type":"application/json"}', '{}', '5000');


--
-- Name: ImageGroups on-image-insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER "on-image-insert" AFTER INSERT ON public."ImageGroups" FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('your_supabase_url/functions/v1/image-notification', 'POST', '{"Content-type":"application/json"}', '{}', '5000');


--
-- Name: Comments Comments_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Comments"
    ADD CONSTRAINT "Comments_group_id_fkey" FOREIGN KEY (group_id) REFERENCES public."Groups"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: Comments Comments_image_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Comments"
    ADD CONSTRAINT "Comments_image_id_fkey" FOREIGN KEY (image_id) REFERENCES public."Images"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: Comments Comments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Comments"
    ADD CONSTRAINT "Comments_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public."Users"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: ImageGroups ImageGroups_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."ImageGroups"
    ADD CONSTRAINT "ImageGroups_group_id_fkey" FOREIGN KEY (group_id) REFERENCES public."Groups"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: ImageGroups ImageGroups_image_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."ImageGroups"
    ADD CONSTRAINT "ImageGroups_image_id_fkey" FOREIGN KEY (image_id) REFERENCES public."Images"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: Images Images_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Images"
    ADD CONSTRAINT "Images_uploaded_by_fkey" FOREIGN KEY (uploaded_by) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: Members Members_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Members"
    ADD CONSTRAINT "Members_group_id_fkey" FOREIGN KEY (group_id) REFERENCES public."Groups"(id);


--
-- Name: Members Members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Members"
    ADD CONSTRAINT "Members_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: Users Users_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Users"
    ADD CONSTRAINT "Users_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: Groups Admins can update the group name; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update the group name" ON public."Groups" FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public."Members"
  WHERE (("Members".group_id = "Groups".id) AND ("Members".user_id = auth.uid()) AND ("Members".admin = true)))));


--
-- Name: Groups Allow admins to delete a group; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow admins to delete a group" ON public."Groups" FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public."Members"
  WHERE (("Members".group_id = "Groups".id) AND ("Members".user_id = auth.uid()) AND ("Members".admin = true)))));


--
-- Name: Groups Allow users to create groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow users to create groups" ON public."Groups" FOR INSERT TO authenticated WITH CHECK ((auth.uid() IS NOT NULL));


--
-- Name: Comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."Comments" ENABLE ROW LEVEL SECURITY;

--
-- Name: Members Enable delete for users based on user_id; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable delete for users based on user_id" ON public."Members" FOR DELETE USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: ImageGroups Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public."ImageGroups" FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: Images Enable insert for authenticated users only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for authenticated users only" ON public."Images" FOR INSERT TO authenticated WITH CHECK (true);


--
-- Name: Users Enable insert for users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for users" ON public."Users" FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = id));


--
-- Name: Members Enable insert for users based on user_id; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for users based on user_id" ON public."Members" FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: Users Enable select for users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable select for users" ON public."Users" FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = id));


--
-- Name: Users Enable update for users based on user_id; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable update for users based on user_id" ON public."Users" FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = id));


--
-- Name: Images Group members can access images of their groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Group members can access images of their groups" ON public."Images" FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM (public."ImageGroups" ig
     JOIN public."Members" m ON ((ig.group_id = m.group_id)))
  WHERE ((ig.image_id = "Images".id) AND (m.user_id = auth.uid())))));


--
-- Name: Groups Group members can see their groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Group members can see their groups" ON public."Groups" FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE ((m.group_id = "Groups".id) AND (m.user_id = auth.uid())))));


--
-- Name: ImageGroups Group members can select images from that group; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Group members can select images from that group" ON public."ImageGroups" FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE ((m.group_id = "ImageGroups".group_id) AND (m.user_id = auth.uid())))));


--
-- Name: Groups; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."Groups" ENABLE ROW LEVEL SECURITY;

--
-- Name: ImageGroups; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."ImageGroups" ENABLE ROW LEVEL SECURITY;

--
-- Name: Images; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."Images" ENABLE ROW LEVEL SECURITY;

--
-- Name: Members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."Members" ENABLE ROW LEVEL SECURITY;

--
-- Name: Comments Only group members can insert comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only group members can insert comments" ON public."Comments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM (public."ImageGroups" ig
     JOIN public."Members" m ON ((ig.group_id = m.group_id)))
  WHERE ((ig.image_id = "Comments".image_id) AND (m.user_id = auth.uid())))));


--
-- Name: Comments Only group members can select comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only group members can select comments" ON public."Comments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM (public."ImageGroups" ig
     JOIN public."Members" m ON ((ig.group_id = m.group_id)))
  WHERE ((ig.image_id = "Comments".image_id) AND (m.user_id = auth.uid())))));


--
-- Name: Users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."Users" ENABLE ROW LEVEL SECURITY;

--
-- Name: Comments Users can delete their own comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete their own comments" ON public."Comments" FOR DELETE USING (((user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM (public."ImageGroups" ig
     JOIN public."Members" m ON ((ig.group_id = m.group_id)))
  WHERE ((ig.image_id = "Comments".image_id) AND (m.user_id = auth.uid()))))));


--
-- Name: Members Users can see members of groups they belong to; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can see members of groups they belong to" ON public."Members" FOR SELECT USING (public.check_user_in_group(auth.uid(), group_id));


--
-- Name: Users Users can see members of their groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can see members of their groups" ON public."Users" FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM (public."Members" m1
     JOIN public."Members" m2 ON ((m1.group_id = m2.group_id)))
  WHERE ((m1.user_id = auth.uid()) AND (m2.user_id = "Users".id)))));


--
-- Name: Comments Users can update their own comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own comments" ON public."Comments" FOR UPDATE USING (((user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM (public."ImageGroups" ig
     JOIN public."Members" m ON ((ig.group_id = m.group_id)))
  WHERE ((ig.image_id = "Comments".image_id) AND (m.user_id = auth.uid()))))));


--
-- Name: Users users update own row; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users update own row" ON public."Users" FOR UPDATE TO authenticated USING ((id = auth.uid())) WITH CHECK ((id = auth.uid()));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION add_comment(group_id uuid, image_id uuid, text text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.add_comment(group_id uuid, image_id uuid, text text) TO anon;
GRANT ALL ON FUNCTION public.add_comment(group_id uuid, image_id uuid, text text) TO authenticated;
GRANT ALL ON FUNCTION public.add_comment(group_id uuid, image_id uuid, text text) TO service_role;


--
-- Name: FUNCTION call_get_group_members_count(p_group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.call_get_group_members_count(p_group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.call_get_group_members_count(p_group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.call_get_group_members_count(p_group_id uuid) TO service_role;


--
-- Name: FUNCTION check_user_in_group(user_uuid uuid, group_uuid uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.check_user_in_group(user_uuid uuid, group_uuid uuid) TO anon;
GRANT ALL ON FUNCTION public.check_user_in_group(user_uuid uuid, group_uuid uuid) TO authenticated;
GRANT ALL ON FUNCTION public.check_user_in_group(user_uuid uuid, group_uuid uuid) TO service_role;


--
-- Name: FUNCTION create_group(group_name text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_group(group_name text) TO anon;
GRANT ALL ON FUNCTION public.create_group(group_name text) TO authenticated;
GRANT ALL ON FUNCTION public.create_group(group_name text) TO service_role;


--
-- Name: FUNCTION create_user_profile(username text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_user_profile(username text) TO anon;
GRANT ALL ON FUNCTION public.create_user_profile(username text) TO authenticated;
GRANT ALL ON FUNCTION public.create_user_profile(username text) TO service_role;


--
-- Name: FUNCTION delete_comment(group_id uuid, image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.delete_comment(group_id uuid, image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.delete_comment(group_id uuid, image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_comment(group_id uuid, image_id uuid) TO service_role;


--
-- Name: FUNCTION delete_image(image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.delete_image(image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.delete_image(image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_image(image_id uuid) TO service_role;


--
-- Name: FUNCTION get_all_images(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_all_images() TO anon;
GRANT ALL ON FUNCTION public.get_all_images() TO authenticated;
GRANT ALL ON FUNCTION public.get_all_images() TO service_role;


--
-- Name: FUNCTION get_comment_count(group_id uuid, image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_comment_count(group_id uuid, image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_comment_count(group_id uuid, image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_comment_count(group_id uuid, image_id uuid) TO service_role;


--
-- Name: FUNCTION get_comments(group_id uuid, image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_comments(group_id uuid, image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_comments(group_id uuid, image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_comments(group_id uuid, image_id uuid) TO service_role;


--
-- Name: FUNCTION get_group_details(group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_group_details(group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_group_details(group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_group_details(group_id uuid) TO service_role;


--
-- Name: FUNCTION get_group_images(p_group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_group_images(p_group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_group_images(p_group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_group_images(p_group_id uuid) TO service_role;


--
-- Name: FUNCTION get_group_members(group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_group_members(group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_group_members(group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_group_members(group_id uuid) TO service_role;


--
-- Name: FUNCTION get_group_members_count(group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_group_members_count(group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_group_members_count(group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_group_members_count(group_id uuid) TO service_role;


--
-- Name: FUNCTION get_image_details(image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_image_details(image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_image_details(image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_image_details(image_id uuid) TO service_role;


--
-- Name: FUNCTION get_latest_image(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_latest_image() TO anon;
GRANT ALL ON FUNCTION public.get_latest_image() TO authenticated;
GRANT ALL ON FUNCTION public.get_latest_image() TO service_role;


--
-- Name: FUNCTION get_user_groups(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_user_groups() TO anon;
GRANT ALL ON FUNCTION public.get_user_groups() TO authenticated;
GRANT ALL ON FUNCTION public.get_user_groups() TO service_role;


--
-- Name: FUNCTION get_username(user_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_username(user_id text) TO anon;
GRANT ALL ON FUNCTION public.get_username(user_id text) TO authenticated;
GRANT ALL ON FUNCTION public.get_username(user_id text) TO service_role;


--
-- Name: FUNCTION handle_storage_delete(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.handle_storage_delete() TO anon;
GRANT ALL ON FUNCTION public.handle_storage_delete() TO authenticated;
GRANT ALL ON FUNCTION public.handle_storage_delete() TO service_role;


--
-- Name: FUNCTION is_admin(group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_admin(group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.is_admin(group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.is_admin(group_id uuid) TO service_role;


--
-- Name: FUNCTION join_group_by_code(group_code text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.join_group_by_code(group_code text) TO anon;
GRANT ALL ON FUNCTION public.join_group_by_code(group_code text) TO authenticated;
GRANT ALL ON FUNCTION public.join_group_by_code(group_code text) TO service_role;


--
-- Name: FUNCTION leave_group(group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.leave_group(group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.leave_group(group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.leave_group(group_id uuid) TO service_role;


--
-- Name: FUNCTION register_uploaded_image(image_id uuid, group_ids text[], image_description text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.register_uploaded_image(image_id uuid, group_ids text[], image_description text) TO postgres;
GRANT ALL ON FUNCTION public.register_uploaded_image(image_id uuid, group_ids text[], image_description text) TO anon;
GRANT ALL ON FUNCTION public.register_uploaded_image(image_id uuid, group_ids text[], image_description text) TO authenticated;
GRANT ALL ON FUNCTION public.register_uploaded_image(image_id uuid, group_ids text[], image_description text) TO service_role;


--
-- Name: FUNCTION remove_group(group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.remove_group(group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.remove_group(group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.remove_group(group_id uuid) TO service_role;


--
-- Name: FUNCTION request_image_uuid(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.request_image_uuid() TO postgres;
GRANT ALL ON FUNCTION public.request_image_uuid() TO anon;
GRANT ALL ON FUNCTION public.request_image_uuid() TO authenticated;
GRANT ALL ON FUNCTION public.request_image_uuid() TO service_role;


--
-- Name: FUNCTION update_comment(group_id uuid, image_id uuid, text text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_comment(group_id uuid, image_id uuid, text text) TO anon;
GRANT ALL ON FUNCTION public.update_comment(group_id uuid, image_id uuid, text text) TO authenticated;
GRANT ALL ON FUNCTION public.update_comment(group_id uuid, image_id uuid, text text) TO service_role;


--
-- Name: FUNCTION update_group_name(group_id uuid, new_name text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_group_name(group_id uuid, new_name text) TO anon;
GRANT ALL ON FUNCTION public.update_group_name(group_id uuid, new_name text) TO authenticated;
GRANT ALL ON FUNCTION public.update_group_name(group_id uuid, new_name text) TO service_role;


--
-- Name: TABLE "Comments"; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public."Comments" TO anon;
GRANT ALL ON TABLE public."Comments" TO authenticated;
GRANT ALL ON TABLE public."Comments" TO service_role;


--
-- Name: TABLE "Groups"; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public."Groups" TO anon;
GRANT ALL ON TABLE public."Groups" TO authenticated;
GRANT ALL ON TABLE public."Groups" TO service_role;


--
-- Name: TABLE "ImageGroups"; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public."ImageGroups" TO anon;
GRANT ALL ON TABLE public."ImageGroups" TO authenticated;
GRANT ALL ON TABLE public."ImageGroups" TO service_role;


--
-- Name: TABLE "Images"; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public."Images" TO anon;
GRANT ALL ON TABLE public."Images" TO authenticated;
GRANT ALL ON TABLE public."Images" TO service_role;


--
-- Name: TABLE "Members"; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public."Members" TO anon;
GRANT ALL ON TABLE public."Members" TO authenticated;
GRANT ALL ON TABLE public."Members" TO service_role;


--
-- Name: TABLE "Users"; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public."Users" TO anon;
GRANT ALL ON TABLE public."Users" TO authenticated;
GRANT ALL ON TABLE public."Users" TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO service_role;


--
-- PostgreSQL database dump complete
--
