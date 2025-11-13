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
-- Name: storage; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA storage;


--
-- Name: buckettype; Type: TYPE; Schema: storage; Owner: -
--

CREATE TYPE storage.buckettype AS ENUM (
    'STANDARD',
    'ANALYTICS'
);


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
-- Name: edit_username(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.edit_username(new_username text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Check if user is logged in
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Check username length
  IF length(trim(new_username)) < 3 THEN
    RAISE EXCEPTION 'Username too short (minimum 3 characters)';
  END IF;

  -- Update the username
  UPDATE public."Users"
  SET username = new_username
  WHERE id = auth.uid();

  -- No profile found
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found for this user';
  END IF;
END;
$$;


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
    AS $$DECLARE
    group_record RECORD;
    is_admin BOOLEAN;
BEGIN
    -- Fetch group details
    SELECT id, created_at, name, code
    INTO group_record
    FROM "Groups"
    WHERE id = get_group_details.group_id;

    IF group_record IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Group not found');
    END IF;

    -- Check if current user is admin in this group
    SELECT admin
    INTO is_admin
    FROM "Members"
    WHERE "Members".group_id = get_group_details.group_id
      AND user_id = auth.uid();

    -- Return group details, without the code if the user isn't admin
    RETURN jsonb_build_object(
        'success', true,
        'group', jsonb_build_object(
            'id', group_record.id,
            'created_at', group_record.created_at,
            'name', group_record.name,
            'code', CASE WHEN is_admin THEN group_record.code ELSE NULL END
        )
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


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

  -- Get all groups the user is a member of, show code only for admins
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', g.id,
      'name', g.name,
      'code', CASE WHEN gm.admin THEN g.code ELSE NULL END,
      'created_at', g.created_at
    )
  )
  INTO user_groups
  FROM "Groups" g
  JOIN "Members" gm ON g.id = gm.group_id
  WHERE gm.user_id = current_user_id;

  RETURN jsonb_build_object(
    'success', true,
    'groups', COALESCE(user_groups, '[]'::jsonb)
  );

EXCEPTION
  WHEN OTHERS THEN
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
    -- Convert user_id
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

  -- Insert/ensure image metadata (id already used for storage key)
  insert into "Images" (id, uploaded_by, description)
  values (register_uploaded_image.image_id, current_user_id, register_uploaded_image.image_description)
  on conflict (id) do nothing;

  -- Insert all authorized group links in one go
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
    -- If something went wrong after creating the image row, you can decide
    -- whether to clean it up. Usually we keep it and let client retry linking.
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

  -- Generate UUID (pgcrypto). If you prefer uuid-ossp, use: uuid_generate_v4()
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


--
-- Name: add_prefixes(text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.add_prefixes(_bucket_id text, _name text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    prefixes text[];
BEGIN
    prefixes := "storage"."get_prefixes"("_name");

    IF array_length(prefixes, 1) > 0 THEN
        INSERT INTO storage.prefixes (name, bucket_id)
        SELECT UNNEST(prefixes) as name, "_bucket_id" ON CONFLICT DO NOTHING;
    END IF;
END;
$$;


--
-- Name: can_insert_object(text, text, uuid, jsonb); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.can_insert_object(bucketid text, name text, owner uuid, metadata jsonb) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO "storage"."objects" ("bucket_id", "name", "owner", "metadata") VALUES (bucketid, name, owner, metadata);
  -- hack to rollback the successful insert
  RAISE sqlstate 'PT200' using
  message = 'ROLLBACK',
  detail = 'rollback successful insert';
END
$$;


--
-- Name: delete_prefix(text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.delete_prefix(_bucket_id text, _name text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Check if we can delete the prefix
    IF EXISTS(
        SELECT FROM "storage"."prefixes"
        WHERE "prefixes"."bucket_id" = "_bucket_id"
          AND level = "storage"."get_level"("_name") + 1
          AND "prefixes"."name" COLLATE "C" LIKE "_name" || '/%'
        LIMIT 1
    )
    OR EXISTS(
        SELECT FROM "storage"."objects"
        WHERE "objects"."bucket_id" = "_bucket_id"
          AND "storage"."get_level"("objects"."name") = "storage"."get_level"("_name") + 1
          AND "objects"."name" COLLATE "C" LIKE "_name" || '/%'
        LIMIT 1
    ) THEN
    -- There are sub-objects, skip deletion
    RETURN false;
    ELSE
        DELETE FROM "storage"."prefixes"
        WHERE "prefixes"."bucket_id" = "_bucket_id"
          AND level = "storage"."get_level"("_name")
          AND "prefixes"."name" = "_name";
        RETURN true;
    END IF;
END;
$$;


--
-- Name: delete_prefix_hierarchy_trigger(); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.delete_prefix_hierarchy_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    prefix text;
BEGIN
    prefix := "storage"."get_prefix"(OLD."name");

    IF coalesce(prefix, '') != '' THEN
        PERFORM "storage"."delete_prefix"(OLD."bucket_id", prefix);
    END IF;

    RETURN OLD;
END;
$$;


--
-- Name: enforce_bucket_name_length(); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.enforce_bucket_name_length() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
    if length(new.name) > 100 then
        raise exception 'bucket name "%" is too long (% characters). Max is 100.', new.name, length(new.name);
    end if;
    return new;
end;
$$;


--
-- Name: extension(text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.extension(name text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    _parts text[];
    _filename text;
BEGIN
    SELECT string_to_array(name, '/') INTO _parts;
    SELECT _parts[array_length(_parts,1)] INTO _filename;
    RETURN reverse(split_part(reverse(_filename), '.', 1));
END
$$;


--
-- Name: filename(text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.filename(name text) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
_parts text[];
BEGIN
	select string_to_array(name, '/') into _parts;
	return _parts[array_length(_parts,1)];
END
$$;


--
-- Name: foldername(text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.foldername(name text) RETURNS text[]
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    _parts text[];
BEGIN
    -- Split on "/" to get path segments
    SELECT string_to_array(name, '/') INTO _parts;
    -- Return everything except the last segment
    RETURN _parts[1 : array_length(_parts,1) - 1];
END
$$;


--
-- Name: get_level(text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.get_level(name text) RETURNS integer
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
SELECT array_length(string_to_array("name", '/'), 1);
$$;


--
-- Name: get_prefix(text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.get_prefix(name text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $_$
SELECT
    CASE WHEN strpos("name", '/') > 0 THEN
             regexp_replace("name", '[\/]{1}[^\/]+\/?$', '')
         ELSE
             ''
        END;
$_$;


--
-- Name: get_prefixes(text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.get_prefixes(name text) RETURNS text[]
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $$
DECLARE
    parts text[];
    prefixes text[];
    prefix text;
BEGIN
    -- Split the name into parts by '/'
    parts := string_to_array("name", '/');
    prefixes := '{}';

    -- Construct the prefixes, stopping one level below the last part
    FOR i IN 1..array_length(parts, 1) - 1 LOOP
            prefix := array_to_string(parts[1:i], '/');
            prefixes := array_append(prefixes, prefix);
    END LOOP;

    RETURN prefixes;
END;
$$;


--
-- Name: get_size_by_bucket(); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.get_size_by_bucket() RETURNS TABLE(size bigint, bucket_id text)
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    return query
        select sum((metadata->>'size')::bigint) as size, obj.bucket_id
        from "storage".objects as obj
        group by obj.bucket_id;
END
$$;


--
-- Name: list_multipart_uploads_with_delimiter(text, text, text, integer, text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.list_multipart_uploads_with_delimiter(bucket_id text, prefix_param text, delimiter_param text, max_keys integer DEFAULT 100, next_key_token text DEFAULT ''::text, next_upload_token text DEFAULT ''::text) RETURNS TABLE(key text, id text, created_at timestamp with time zone)
    LANGUAGE plpgsql
    AS $_$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT DISTINCT ON(key COLLATE "C") * from (
            SELECT
                CASE
                    WHEN position($2 IN substring(key from length($1) + 1)) > 0 THEN
                        substring(key from 1 for length($1) + position($2 IN substring(key from length($1) + 1)))
                    ELSE
                        key
                END AS key, id, created_at
            FROM
                storage.s3_multipart_uploads
            WHERE
                bucket_id = $5 AND
                key ILIKE $1 || ''%'' AND
                CASE
                    WHEN $4 != '''' AND $6 = '''' THEN
                        CASE
                            WHEN position($2 IN substring(key from length($1) + 1)) > 0 THEN
                                substring(key from 1 for length($1) + position($2 IN substring(key from length($1) + 1))) COLLATE "C" > $4
                            ELSE
                                key COLLATE "C" > $4
                            END
                    ELSE
                        true
                END AND
                CASE
                    WHEN $6 != '''' THEN
                        id COLLATE "C" > $6
                    ELSE
                        true
                    END
            ORDER BY
                key COLLATE "C" ASC, created_at ASC) as e order by key COLLATE "C" LIMIT $3'
        USING prefix_param, delimiter_param, max_keys, next_key_token, bucket_id, next_upload_token;
END;
$_$;


--
-- Name: list_objects_with_delimiter(text, text, text, integer, text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.list_objects_with_delimiter(bucket_id text, prefix_param text, delimiter_param text, max_keys integer DEFAULT 100, start_after text DEFAULT ''::text, next_token text DEFAULT ''::text) RETURNS TABLE(name text, id uuid, metadata jsonb, updated_at timestamp with time zone)
    LANGUAGE plpgsql
    AS $_$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT DISTINCT ON(name COLLATE "C") * from (
            SELECT
                CASE
                    WHEN position($2 IN substring(name from length($1) + 1)) > 0 THEN
                        substring(name from 1 for length($1) + position($2 IN substring(name from length($1) + 1)))
                    ELSE
                        name
                END AS name, id, metadata, updated_at
            FROM
                storage.objects
            WHERE
                bucket_id = $5 AND
                name ILIKE $1 || ''%'' AND
                CASE
                    WHEN $6 != '''' THEN
                    name COLLATE "C" > $6
                ELSE true END
                AND CASE
                    WHEN $4 != '''' THEN
                        CASE
                            WHEN position($2 IN substring(name from length($1) + 1)) > 0 THEN
                                substring(name from 1 for length($1) + position($2 IN substring(name from length($1) + 1))) COLLATE "C" > $4
                            ELSE
                                name COLLATE "C" > $4
                            END
                    ELSE
                        true
                END
            ORDER BY
                name COLLATE "C" ASC) as e order by name COLLATE "C" LIMIT $3'
        USING prefix_param, delimiter_param, max_keys, next_token, bucket_id, start_after;
END;
$_$;


--
-- Name: objects_insert_prefix_trigger(); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.objects_insert_prefix_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM "storage"."add_prefixes"(NEW."bucket_id", NEW."name");
    NEW.level := "storage"."get_level"(NEW."name");

    RETURN NEW;
END;
$$;


--
-- Name: objects_update_prefix_trigger(); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.objects_update_prefix_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    old_prefixes TEXT[];
BEGIN
    -- Ensure this is an update operation and the name has changed
    IF TG_OP = 'UPDATE' AND (NEW."name" <> OLD."name" OR NEW."bucket_id" <> OLD."bucket_id") THEN
        -- Retrieve old prefixes
        old_prefixes := "storage"."get_prefixes"(OLD."name");

        -- Remove old prefixes that are only used by this object
        WITH all_prefixes as (
            SELECT unnest(old_prefixes) as prefix
        ),
        can_delete_prefixes as (
             SELECT prefix
             FROM all_prefixes
             WHERE NOT EXISTS (
                 SELECT 1 FROM "storage"."objects"
                 WHERE "bucket_id" = OLD."bucket_id"
                   AND "name" <> OLD."name"
                   AND "name" LIKE (prefix || '%')
             )
         )
        DELETE FROM "storage"."prefixes" WHERE name IN (SELECT prefix FROM can_delete_prefixes);

        -- Add new prefixes
        PERFORM "storage"."add_prefixes"(NEW."bucket_id", NEW."name");
    END IF;
    -- Set the new level
    NEW."level" := "storage"."get_level"(NEW."name");

    RETURN NEW;
END;
$$;


--
-- Name: operation(); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.operation() RETURNS text
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    RETURN current_setting('storage.operation', true);
END;
$$;


--
-- Name: prefixes_insert_trigger(); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.prefixes_insert_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM "storage"."add_prefixes"(NEW."bucket_id", NEW."name");
    RETURN NEW;
END;
$$;


--
-- Name: search(text, text, integer, integer, integer, text, text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.search(prefix text, bucketname text, limits integer DEFAULT 100, levels integer DEFAULT 1, offsets integer DEFAULT 0, search text DEFAULT ''::text, sortcolumn text DEFAULT 'name'::text, sortorder text DEFAULT 'asc'::text) RETURNS TABLE(name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, metadata jsonb)
    LANGUAGE plpgsql
    AS $$
declare
    can_bypass_rls BOOLEAN;
begin
    SELECT rolbypassrls
    INTO can_bypass_rls
    FROM pg_roles
    WHERE rolname = coalesce(nullif(current_setting('role', true), 'none'), current_user);

    IF can_bypass_rls THEN
        RETURN QUERY SELECT * FROM storage.search_v1_optimised(prefix, bucketname, limits, levels, offsets, search, sortcolumn, sortorder);
    ELSE
        RETURN QUERY SELECT * FROM storage.search_legacy_v1(prefix, bucketname, limits, levels, offsets, search, sortcolumn, sortorder);
    END IF;
end;
$$;


--
-- Name: search_legacy_v1(text, text, integer, integer, integer, text, text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.search_legacy_v1(prefix text, bucketname text, limits integer DEFAULT 100, levels integer DEFAULT 1, offsets integer DEFAULT 0, search text DEFAULT ''::text, sortcolumn text DEFAULT 'name'::text, sortorder text DEFAULT 'asc'::text) RETURNS TABLE(name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, metadata jsonb)
    LANGUAGE plpgsql STABLE
    AS $_$
declare
    v_order_by text;
    v_sort_order text;
begin
    case
        when sortcolumn = 'name' then
            v_order_by = 'name';
        when sortcolumn = 'updated_at' then
            v_order_by = 'updated_at';
        when sortcolumn = 'created_at' then
            v_order_by = 'created_at';
        when sortcolumn = 'last_accessed_at' then
            v_order_by = 'last_accessed_at';
        else
            v_order_by = 'name';
        end case;

    case
        when sortorder = 'asc' then
            v_sort_order = 'asc';
        when sortorder = 'desc' then
            v_sort_order = 'desc';
        else
            v_sort_order = 'asc';
        end case;

    v_order_by = v_order_by || ' ' || v_sort_order;

    return query execute
        'with folders as (
           select path_tokens[$1] as folder
           from storage.objects
             where objects.name ilike $2 || $3 || ''%''
               and bucket_id = $4
               and array_length(objects.path_tokens, 1) <> $1
           group by folder
           order by folder ' || v_sort_order || '
     )
     (select folder as "name",
            null as id,
            null as updated_at,
            null as created_at,
            null as last_accessed_at,
            null as metadata from folders)
     union all
     (select path_tokens[$1] as "name",
            id,
            updated_at,
            created_at,
            last_accessed_at,
            metadata
     from storage.objects
     where objects.name ilike $2 || $3 || ''%''
       and bucket_id = $4
       and array_length(objects.path_tokens, 1) = $1
     order by ' || v_order_by || ')
     limit $5
     offset $6' using levels, prefix, search, bucketname, limits, offsets;
end;
$_$;


--
-- Name: search_v1_optimised(text, text, integer, integer, integer, text, text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.search_v1_optimised(prefix text, bucketname text, limits integer DEFAULT 100, levels integer DEFAULT 1, offsets integer DEFAULT 0, search text DEFAULT ''::text, sortcolumn text DEFAULT 'name'::text, sortorder text DEFAULT 'asc'::text) RETURNS TABLE(name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, metadata jsonb)
    LANGUAGE plpgsql STABLE
    AS $_$
declare
    v_order_by text;
    v_sort_order text;
begin
    case
        when sortcolumn = 'name' then
            v_order_by = 'name';
        when sortcolumn = 'updated_at' then
            v_order_by = 'updated_at';
        when sortcolumn = 'created_at' then
            v_order_by = 'created_at';
        when sortcolumn = 'last_accessed_at' then
            v_order_by = 'last_accessed_at';
        else
            v_order_by = 'name';
        end case;

    case
        when sortorder = 'asc' then
            v_sort_order = 'asc';
        when sortorder = 'desc' then
            v_sort_order = 'desc';
        else
            v_sort_order = 'asc';
        end case;

    v_order_by = v_order_by || ' ' || v_sort_order;

    return query execute
        'with folders as (
           select (string_to_array(name, ''/''))[level] as name
           from storage.prefixes
             where lower(prefixes.name) like lower($2 || $3) || ''%''
               and bucket_id = $4
               and level = $1
           order by name ' || v_sort_order || '
     )
     (select name,
            null as id,
            null as updated_at,
            null as created_at,
            null as last_accessed_at,
            null as metadata from folders)
     union all
     (select path_tokens[level] as "name",
            id,
            updated_at,
            created_at,
            last_accessed_at,
            metadata
     from storage.objects
     where lower(objects.name) like lower($2 || $3) || ''%''
       and bucket_id = $4
       and level = $1
     order by ' || v_order_by || ')
     limit $5
     offset $6' using levels, prefix, search, bucketname, limits, offsets;
end;
$_$;


--
-- Name: search_v2(text, text, integer, integer, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.search_v2(prefix text, bucket_name text, limits integer DEFAULT 100, levels integer DEFAULT 1, start_after text DEFAULT ''::text) RETURNS TABLE(key text, name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, metadata jsonb)
    LANGUAGE plpgsql STABLE
    AS $_$
BEGIN
    RETURN query EXECUTE
        $sql$
        SELECT * FROM (
            (
                SELECT
                    split_part(name, '/', $4) AS key,
                    name || '/' AS name,
                    NULL::uuid AS id,
                    NULL::timestamptz AS updated_at,
                    NULL::timestamptz AS created_at,
                    NULL::jsonb AS metadata
                FROM storage.prefixes
                WHERE name COLLATE "C" LIKE $1 || '%'
                AND bucket_id = $2
                AND level = $4
                AND name COLLATE "C" > $5
                ORDER BY prefixes.name COLLATE "C" LIMIT $3
            )
            UNION ALL
            (SELECT split_part(name, '/', $4) AS key,
                name,
                id,
                updated_at,
                created_at,
                metadata
            FROM storage.objects
            WHERE name COLLATE "C" LIKE $1 || '%'
                AND bucket_id = $2
                AND level = $4
                AND name COLLATE "C" > $5
            ORDER BY name COLLATE "C" LIMIT $3)
        ) obj
        ORDER BY name COLLATE "C" LIMIT $3;
        $sql$
        USING prefix, bucket_name, limits, levels, start_after;
END;
$_$;


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


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
    owner uuid,
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
-- Name: buckets; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.buckets (
    id text NOT NULL,
    name text NOT NULL,
    owner uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    public boolean DEFAULT false,
    avif_autodetection boolean DEFAULT false,
    file_size_limit bigint,
    allowed_mime_types text[],
    owner_id text,
    type storage.buckettype DEFAULT 'STANDARD'::storage.buckettype NOT NULL
);


--
-- Name: COLUMN buckets.owner; Type: COMMENT; Schema: storage; Owner: -
--

COMMENT ON COLUMN storage.buckets.owner IS 'Field is deprecated, use owner_id instead';


--
-- Name: buckets_analytics; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.buckets_analytics (
    id text NOT NULL,
    type storage.buckettype DEFAULT 'ANALYTICS'::storage.buckettype NOT NULL,
    format text DEFAULT 'ICEBERG'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: iceberg_namespaces; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.iceberg_namespaces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    bucket_id text NOT NULL,
    name text NOT NULL COLLATE pg_catalog."C",
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: iceberg_tables; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.iceberg_tables (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    namespace_id uuid NOT NULL,
    bucket_id text NOT NULL,
    name text NOT NULL COLLATE pg_catalog."C",
    location text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: migrations; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.migrations (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    hash character varying(40) NOT NULL,
    executed_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: objects; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.objects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    bucket_id text,
    name text,
    owner uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    last_accessed_at timestamp with time zone DEFAULT now(),
    metadata jsonb,
    path_tokens text[] GENERATED ALWAYS AS (string_to_array(name, '/'::text)) STORED,
    version text,
    owner_id text,
    user_metadata jsonb,
    level integer
);


--
-- Name: COLUMN objects.owner; Type: COMMENT; Schema: storage; Owner: -
--

COMMENT ON COLUMN storage.objects.owner IS 'Field is deprecated, use owner_id instead';


--
-- Name: prefixes; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.prefixes (
    bucket_id text NOT NULL,
    name text NOT NULL COLLATE pg_catalog."C",
    level integer GENERATED ALWAYS AS (storage.get_level(name)) STORED NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: s3_multipart_uploads; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.s3_multipart_uploads (
    id text NOT NULL,
    in_progress_size bigint DEFAULT 0 NOT NULL,
    upload_signature text NOT NULL,
    bucket_id text NOT NULL,
    key text NOT NULL COLLATE pg_catalog."C",
    version text NOT NULL,
    owner_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    user_metadata jsonb
);


--
-- Name: s3_multipart_uploads_parts; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.s3_multipart_uploads_parts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    upload_id text NOT NULL,
    size bigint DEFAULT 0 NOT NULL,
    part_number integer NOT NULL,
    bucket_id text NOT NULL,
    key text NOT NULL COLLATE pg_catalog."C",
    etag text NOT NULL,
    owner_id text,
    version text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


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
-- Name: buckets_analytics buckets_analytics_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.buckets_analytics
    ADD CONSTRAINT buckets_analytics_pkey PRIMARY KEY (id);


--
-- Name: buckets buckets_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.buckets
    ADD CONSTRAINT buckets_pkey PRIMARY KEY (id);


--
-- Name: iceberg_namespaces iceberg_namespaces_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.iceberg_namespaces
    ADD CONSTRAINT iceberg_namespaces_pkey PRIMARY KEY (id);


--
-- Name: iceberg_tables iceberg_tables_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.iceberg_tables
    ADD CONSTRAINT iceberg_tables_pkey PRIMARY KEY (id);


--
-- Name: migrations migrations_name_key; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.migrations
    ADD CONSTRAINT migrations_name_key UNIQUE (name);


--
-- Name: migrations migrations_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (id);


--
-- Name: objects objects_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.objects
    ADD CONSTRAINT objects_pkey PRIMARY KEY (id);


--
-- Name: prefixes prefixes_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.prefixes
    ADD CONSTRAINT prefixes_pkey PRIMARY KEY (bucket_id, level, name);


--
-- Name: s3_multipart_uploads_parts s3_multipart_uploads_parts_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.s3_multipart_uploads_parts
    ADD CONSTRAINT s3_multipart_uploads_parts_pkey PRIMARY KEY (id);


--
-- Name: s3_multipart_uploads s3_multipart_uploads_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.s3_multipart_uploads
    ADD CONSTRAINT s3_multipart_uploads_pkey PRIMARY KEY (id);


--
-- Name: bname; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX bname ON storage.buckets USING btree (name);


--
-- Name: bucketid_objname; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX bucketid_objname ON storage.objects USING btree (bucket_id, name);


--
-- Name: idx_iceberg_namespaces_bucket_id; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX idx_iceberg_namespaces_bucket_id ON storage.iceberg_namespaces USING btree (bucket_id, name);


--
-- Name: idx_iceberg_tables_namespace_id; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX idx_iceberg_tables_namespace_id ON storage.iceberg_tables USING btree (namespace_id, name);


--
-- Name: idx_multipart_uploads_list; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX idx_multipart_uploads_list ON storage.s3_multipart_uploads USING btree (bucket_id, key, created_at);


--
-- Name: idx_name_bucket_level_unique; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX idx_name_bucket_level_unique ON storage.objects USING btree (name COLLATE "C", bucket_id, level);


--
-- Name: idx_objects_bucket_id_name; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX idx_objects_bucket_id_name ON storage.objects USING btree (bucket_id, name COLLATE "C");


--
-- Name: idx_objects_lower_name; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX idx_objects_lower_name ON storage.objects USING btree ((path_tokens[level]), lower(name) text_pattern_ops, bucket_id, level);


--
-- Name: idx_prefixes_lower_name; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX idx_prefixes_lower_name ON storage.prefixes USING btree (bucket_id, level, ((string_to_array(name, '/'::text))[level]), lower(name) text_pattern_ops);


--
-- Name: name_prefix_search; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX name_prefix_search ON storage.objects USING btree (name text_pattern_ops);


--
-- Name: objects_bucket_id_level_idx; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX objects_bucket_id_level_idx ON storage.objects USING btree (bucket_id, level, name COLLATE "C");


--
-- Name: Comments on-comment-insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER "on-comment-insert" AFTER INSERT ON public."Comments" FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('your_supabase_url/functions/v1/comment-notification', 'POST', '{"Content-type":"application/json"}', '{}', '5000');


--
-- Name: ImageGroups on-image-insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER "on-image-insert" AFTER INSERT ON public."ImageGroups" FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('your_supabase_url/functions/v1/image-notification', 'POST', '{"Content-type":"application/json"}', '{}', '5000');


--
-- Name: buckets enforce_bucket_name_length_trigger; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER enforce_bucket_name_length_trigger BEFORE INSERT OR UPDATE OF name ON storage.buckets FOR EACH ROW EXECUTE FUNCTION storage.enforce_bucket_name_length();


--
-- Name: objects objects_delete_delete_prefix; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER objects_delete_delete_prefix AFTER DELETE ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.delete_prefix_hierarchy_trigger();


--
-- Name: objects objects_insert_create_prefix; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER objects_insert_create_prefix BEFORE INSERT ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.objects_insert_prefix_trigger();


--
-- Name: objects objects_update_create_prefix; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER objects_update_create_prefix BEFORE UPDATE ON storage.objects FOR EACH ROW WHEN (((new.name <> old.name) OR (new.bucket_id <> old.bucket_id))) EXECUTE FUNCTION storage.objects_update_prefix_trigger();


--
-- Name: objects on_storage_object_delete; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER on_storage_object_delete AFTER DELETE ON storage.objects FOR EACH ROW EXECUTE FUNCTION public.handle_storage_delete();


--
-- Name: prefixes prefixes_create_hierarchy; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER prefixes_create_hierarchy BEFORE INSERT ON storage.prefixes FOR EACH ROW WHEN ((pg_trigger_depth() < 1)) EXECUTE FUNCTION storage.prefixes_insert_trigger();


--
-- Name: prefixes prefixes_delete_hierarchy; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER prefixes_delete_hierarchy AFTER DELETE ON storage.prefixes FOR EACH ROW EXECUTE FUNCTION storage.delete_prefix_hierarchy_trigger();


--
-- Name: objects update_objects_updated_at; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER update_objects_updated_at BEFORE UPDATE ON storage.objects FOR EACH ROW EXECUTE FUNCTION storage.update_updated_at_column();


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
-- Name: Groups Groups_owner_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Groups"
    ADD CONSTRAINT "Groups_owner_fkey" FOREIGN KEY (owner) REFERENCES public."Users"(id) ON UPDATE CASCADE ON DELETE SET NULL;


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
-- Name: iceberg_namespaces iceberg_namespaces_bucket_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.iceberg_namespaces
    ADD CONSTRAINT iceberg_namespaces_bucket_id_fkey FOREIGN KEY (bucket_id) REFERENCES storage.buckets_analytics(id) ON DELETE CASCADE;


--
-- Name: iceberg_tables iceberg_tables_bucket_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.iceberg_tables
    ADD CONSTRAINT iceberg_tables_bucket_id_fkey FOREIGN KEY (bucket_id) REFERENCES storage.buckets_analytics(id) ON DELETE CASCADE;


--
-- Name: iceberg_tables iceberg_tables_namespace_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.iceberg_tables
    ADD CONSTRAINT iceberg_tables_namespace_id_fkey FOREIGN KEY (namespace_id) REFERENCES storage.iceberg_namespaces(id) ON DELETE CASCADE;


--
-- Name: objects objects_bucketId_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.objects
    ADD CONSTRAINT "objects_bucketId_fkey" FOREIGN KEY (bucket_id) REFERENCES storage.buckets(id);


--
-- Name: prefixes prefixes_bucketId_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.prefixes
    ADD CONSTRAINT "prefixes_bucketId_fkey" FOREIGN KEY (bucket_id) REFERENCES storage.buckets(id);


--
-- Name: s3_multipart_uploads s3_multipart_uploads_bucket_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.s3_multipart_uploads
    ADD CONSTRAINT s3_multipart_uploads_bucket_id_fkey FOREIGN KEY (bucket_id) REFERENCES storage.buckets(id);


--
-- Name: s3_multipart_uploads_parts s3_multipart_uploads_parts_bucket_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.s3_multipart_uploads_parts
    ADD CONSTRAINT s3_multipart_uploads_parts_bucket_id_fkey FOREIGN KEY (bucket_id) REFERENCES storage.buckets(id);


--
-- Name: s3_multipart_uploads_parts s3_multipart_uploads_parts_upload_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.s3_multipart_uploads_parts
    ADD CONSTRAINT s3_multipart_uploads_parts_upload_id_fkey FOREIGN KEY (upload_id) REFERENCES storage.s3_multipart_uploads(id) ON DELETE CASCADE;


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
-- Name: objects Give users authenticated access to insert; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Give users authenticated access to insert" ON storage.objects FOR INSERT TO authenticated WITH CHECK (((auth.uid() IS NOT NULL) AND (bucket_id = 'images'::text)));


--
-- Name: objects Group admins can update the group icon 1tf5vm4_0; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Group admins can update the group icon 1tf5vm4_0" ON storage.objects FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'group-icons'::text) AND (EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE (((m.group_id)::text = objects.name) AND (m.user_id = auth.uid()) AND (m.admin = true))))));


--
-- Name: objects Group admins can update the group icon 1tf5vm4_1; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Group admins can update the group icon 1tf5vm4_1" ON storage.objects FOR UPDATE TO authenticated USING (((bucket_id = 'group-icons'::text) AND (EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE (((m.group_id)::text = objects.name) AND (m.user_id = auth.uid()) AND (m.admin = true))))));


--
-- Name: objects Group admins can update the group icon 1tf5vm4_2; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Group admins can update the group icon 1tf5vm4_2" ON storage.objects FOR DELETE TO authenticated USING (((bucket_id = 'group-icons'::text) AND (EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE (((m.group_id)::text = objects.name) AND (m.user_id = auth.uid()) AND (m.admin = true))))));


--
-- Name: objects Group members can access the group icon 1tf5vm4_0; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Group members can access the group icon 1tf5vm4_0" ON storage.objects FOR SELECT TO authenticated USING (((bucket_id = 'group-icons'::text) AND (EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE (((m.group_id)::text = objects.name) AND (m.user_id = auth.uid()))))));


--
-- Name: objects Group members can see the group images; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Group members can see the group images" ON storage.objects FOR SELECT TO authenticated USING (((bucket_id = 'images'::text) AND (EXISTS ( WITH user_groups AS (
         SELECT "Members".group_id
           FROM public."Members"
          WHERE ("Members".user_id = auth.uid())
        )
 SELECT 1
   FROM (public."ImageGroups" ig
     JOIN user_groups ug ON ((ig.group_id = ug.group_id)))
  WHERE (ig.image_id = (objects.name)::uuid)))));


--
-- Name: objects Users can manage their own profile picture 1skn4k9_0; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Users can manage their own profile picture 1skn4k9_0" ON storage.objects FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'profile-pictures'::text) AND (name = (auth.uid())::text)));


--
-- Name: objects Users can manage their own profile picture 1skn4k9_1; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Users can manage their own profile picture 1skn4k9_1" ON storage.objects FOR UPDATE TO authenticated USING (((bucket_id = 'profile-pictures'::text) AND (name = (auth.uid())::text)));


--
-- Name: objects Users can manage their own profile picture 1skn4k9_2; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Users can manage their own profile picture 1skn4k9_2" ON storage.objects FOR DELETE TO authenticated USING (((bucket_id = 'profile-pictures'::text) AND (name = (auth.uid())::text)));


--
-- Name: objects Users can see their pfps and users in their group; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Users can see their pfps and users in their group" ON storage.objects FOR SELECT USING (((bucket_id = 'profile-pictures'::text) AND ((name = (auth.uid())::text) OR (EXISTS ( SELECT 1
   FROM (public."Members" gm1
     JOIN public."Members" gm2 ON ((gm1.group_id = gm2.group_id)))
  WHERE ((gm1.user_id = auth.uid()) AND (gm2.user_id = (objects.name)::uuid)))))));


--
-- Name: buckets; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;

--
-- Name: buckets_analytics; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.buckets_analytics ENABLE ROW LEVEL SECURITY;

--
-- Name: iceberg_namespaces; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.iceberg_namespaces ENABLE ROW LEVEL SECURITY;

--
-- Name: iceberg_tables; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.iceberg_tables ENABLE ROW LEVEL SECURITY;

--
-- Name: migrations; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.migrations ENABLE ROW LEVEL SECURITY;

--
-- Name: objects; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

--
-- Name: prefixes; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.prefixes ENABLE ROW LEVEL SECURITY;

--
-- Name: s3_multipart_uploads; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.s3_multipart_uploads ENABLE ROW LEVEL SECURITY;

--
-- Name: s3_multipart_uploads_parts; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.s3_multipart_uploads_parts ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: SCHEMA storage; Type: ACL; Schema: -; Owner: -
--

GRANT ALL ON SCHEMA storage TO postgres;
GRANT USAGE ON SCHEMA storage TO anon;
GRANT USAGE ON SCHEMA storage TO authenticated;
GRANT USAGE ON SCHEMA storage TO service_role;
GRANT ALL ON SCHEMA storage TO supabase_storage_admin;
GRANT ALL ON SCHEMA storage TO dashboard_user;


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
-- Name: FUNCTION edit_username(new_username text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.edit_username(new_username text) TO postgres;
GRANT ALL ON FUNCTION public.edit_username(new_username text) TO anon;
GRANT ALL ON FUNCTION public.edit_username(new_username text) TO authenticated;
GRANT ALL ON FUNCTION public.edit_username(new_username text) TO service_role;


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
-- Name: TABLE buckets; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.buckets TO anon;
GRANT ALL ON TABLE storage.buckets TO authenticated;
GRANT ALL ON TABLE storage.buckets TO service_role;
GRANT ALL ON TABLE storage.buckets TO postgres;


--
-- Name: TABLE buckets_analytics; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.buckets_analytics TO service_role;
GRANT ALL ON TABLE storage.buckets_analytics TO authenticated;
GRANT ALL ON TABLE storage.buckets_analytics TO anon;


--
-- Name: TABLE iceberg_namespaces; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.iceberg_namespaces TO service_role;
GRANT SELECT ON TABLE storage.iceberg_namespaces TO authenticated;
GRANT SELECT ON TABLE storage.iceberg_namespaces TO anon;


--
-- Name: TABLE iceberg_tables; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.iceberg_tables TO service_role;
GRANT SELECT ON TABLE storage.iceberg_tables TO authenticated;
GRANT SELECT ON TABLE storage.iceberg_tables TO anon;


--
-- Name: TABLE migrations; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.migrations TO anon;
GRANT ALL ON TABLE storage.migrations TO authenticated;
GRANT ALL ON TABLE storage.migrations TO service_role;
GRANT ALL ON TABLE storage.migrations TO postgres;


--
-- Name: TABLE objects; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.objects TO anon;
GRANT ALL ON TABLE storage.objects TO authenticated;
GRANT ALL ON TABLE storage.objects TO service_role;
GRANT ALL ON TABLE storage.objects TO postgres;


--
-- Name: TABLE prefixes; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.prefixes TO service_role;
GRANT ALL ON TABLE storage.prefixes TO authenticated;
GRANT ALL ON TABLE storage.prefixes TO anon;


--
-- Name: TABLE s3_multipart_uploads; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.s3_multipart_uploads TO service_role;
GRANT SELECT ON TABLE storage.s3_multipart_uploads TO authenticated;
GRANT SELECT ON TABLE storage.s3_multipart_uploads TO anon;


--
-- Name: TABLE s3_multipart_uploads_parts; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.s3_multipart_uploads_parts TO service_role;
GRANT SELECT ON TABLE storage.s3_multipart_uploads_parts TO authenticated;
GRANT SELECT ON TABLE storage.s3_multipart_uploads_parts TO anon;


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
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: storage; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON SEQUENCES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON SEQUENCES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON SEQUENCES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON SEQUENCES  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: storage; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON FUNCTIONS  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON FUNCTIONS  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON FUNCTIONS  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON FUNCTIONS  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: storage; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON TABLES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON TABLES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON TABLES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON TABLES  TO service_role;


--
-- PostgreSQL database dump complete
--

