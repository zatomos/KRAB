--
-- PostgreSQL database dump
--

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
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
    'ANALYTICS',
    'VECTOR'
);


--
-- Name: add_comment(uuid, uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_comment(image_id uuid, group_id uuid, text text, parent_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id UUID;
  new_comment_id UUID;
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
      AND m.role <> 'banned'
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

  -- If replying, validate parent comment exists in same image/group
  IF add_comment.parent_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM "Comments" c
      WHERE c.id = add_comment.parent_id
        AND c.image_id = add_comment.image_id
        AND c.group_id = add_comment.group_id
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Parent comment not found'
      );
    END IF;
  END IF;

  -- Insert comment
  INSERT INTO "Comments" (user_id, image_id, group_id, text, parent_id)
  VALUES (current_user_id, add_comment.image_id, add_comment.group_id, add_comment.text, add_comment.parent_id)
  RETURNING id INTO new_comment_id;

  RETURN jsonb_build_object(
    'success', true,
    'comment_id', new_comment_id
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;$$;


--
-- Name: add_image_to_groups(uuid, uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_image_to_groups(p_image_id uuid, p_group_ids uuid[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  added_count int := 0;
BEGIN
  current_user_id := auth.uid();

  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  -- Only the uploader can re-share their own image.
  IF NOT EXISTS (
    SELECT 1 FROM "Images" i
    WHERE i.id = p_image_id AND i.uploaded_by = current_user_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Image not found or permission denied');
  END IF;

  -- Insert links only for groups the user is an active (non-banned) member of;
  -- skip groups the image is already in.
  WITH inserted AS (
    INSERT INTO "ImageGroups" (image_id, group_id)
    SELECT p_image_id, g
    FROM unnest(p_group_ids) AS g
    WHERE EXISTS (
      SELECT 1 FROM "Members" m
      WHERE m.user_id = current_user_id
        AND m.group_id = g
        AND m.role <> 'banned'
    )
    ON CONFLICT (image_id, group_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO added_count FROM inserted;

  RETURN jsonb_build_object('success', true, 'added', added_count);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: ban_user(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ban_user(group_id uuid, target_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  user_role text;
  target_role text;
  rows_updated integer;
BEGIN
  -- Check caller role
  SELECT role INTO user_role
  FROM "Members" m
  WHERE m.group_id = ban_user.group_id
  AND m.user_id = auth.uid();

  IF user_role NOT IN ('owner','admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only admins or owners can ban');
  END IF;

  -- Fetch target role
  SELECT role INTO target_role
  FROM "Members" m
  WHERE m.group_id = ban_user.group_id
  AND m.user_id = ban_user.target_user_id;

  IF target_role IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not in group');
  END IF;

  -- Owners cannot be banned
  IF target_role = 'owner' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cannot ban the owner');
  END IF;

  -- Admins cannot ban other admins
  IF user_role = 'admin' AND target_role = 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Admins cannot ban other admins');
  END IF;

  -- Ban logic
  UPDATE "Members" m
  SET role = 'banned'
  WHERE m.group_id = ban_user.group_id AND m.user_id = ban_user.target_user_id;

  GET DIAGNOSTICS rows_updated = ROW_COUNT;

  IF rows_updated = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Failed to ban user');
  END IF;

  RETURN jsonb_build_object('success', true, 'message', 'User banned successfully');

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: check_user_in_group(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_user_in_group(user_uuid uuid, group_uuid uuid) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM "Members"
    WHERE user_id = user_uuid AND group_id = group_uuid
  );
END;$$;


--
-- Name: create_group(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_group(group_name text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
    new_group_id UUID;
BEGIN
    -- Generate a new UUID for the group
    new_group_id := gen_random_uuid();

    -- Insert the new group
    INSERT INTO "public"."Groups" (id, name)
    VALUES (new_group_id, group_name);

    -- Make the creator owner
    INSERT INTO "public"."Members" (user_id, group_id, role)
    VALUES (auth.uid(), new_group_id, 'owner');

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Group created successfully',
        'group_id', new_group_id
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;$$;


--
-- Name: create_group_invite(uuid, timestamp with time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_group_invite(p_group_id uuid, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_max_uses integer DEFAULT NULL::integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  uid uuid := auth.uid();
  v_permission text;
  v_role text;
  v_token text;
BEGIN
  IF uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT invite_permission INTO v_permission
  FROM "Groups" WHERE id = p_group_id;

  IF v_permission IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Group not found');
  END IF;

  SELECT role INTO v_role
  FROM "Members" WHERE group_id = p_group_id AND user_id = uid;

  IF v_role IS NULL OR v_role = 'banned' THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are not a member of this group');
  END IF;

  IF NOT (
       v_role = 'owner'
    OR (v_permission = 'admin'    AND v_role = 'admin')
    OR (v_permission = 'everyone' AND v_role IN ('admin', 'member'))
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You do not have permission to create invites for this group');
  END IF;

  IF p_max_uses IS NOT NULL AND p_max_uses < 1 THEN
    RETURN jsonb_build_object('success', false, 'error', 'max_uses must be at least 1');
  END IF;

  INSERT INTO "GroupInvites" (group_id, created_by, expires_at, max_uses)
  VALUES (p_group_id, uid, p_expires_at, p_max_uses)
  RETURNING token INTO v_token;

  RETURN jsonb_build_object('success', true, 'token', v_token);
END;$$;


--
-- Name: create_user_profile(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_user_profile(username text) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$BEGIN
    INSERT INTO "public"."Users" (id, username)
    VALUES ((SELECT auth.uid()), username);
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;$$;


--
-- Name: delete_account(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_account() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  current_user_id uuid;
BEGIN
  current_user_id := auth.uid();

  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  -- Owners must hand off or delete their groups first
  IF EXISTS (
    SELECT 1 FROM "Members" m
    WHERE m.user_id = current_user_id AND m.role = 'owner'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'owns_groups');
  END IF;

  -- Remove the user's photos from every group they were shared to
  DELETE FROM "ImageGroups" ig
    USING "Images" i
   WHERE ig.image_id = i.id
     AND i.uploaded_by = current_user_id;

  -- Clear user's membership
  DELETE FROM "Members" m WHERE m.user_id = current_user_id;

  -- Deleting the auth user cascades to public."Users" and from there
  -- to Comments, Reactions, NotifiedImageUsers and GroupInvites, plus the
  -- user's now-groupless Images.
  DELETE FROM auth.users WHERE id = current_user_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


--
-- Name: delete_comment(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_comment(comment_id uuid, image_id uuid, group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id UUID;
  has_children BOOLEAN;
BEGIN
  current_user_id := auth.uid();

  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM "Members" m
    WHERE m.user_id = current_user_id
      AND m.group_id = delete_comment.group_id
      AND m.role <> 'banned'
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'You are not a member of this group'
    );
  END IF;

  -- Check if the comment has children
  SELECT EXISTS (
    SELECT 1
    FROM "Comments"
    WHERE parent_id = delete_comment.comment_id
  )
  INTO has_children;

  IF has_children THEN
    -- Soft delete: replace content
    UPDATE "Comments" c
    SET text = '[deleted by user]'
    WHERE id = delete_comment.comment_id
      AND c.image_id = delete_comment.image_id
      AND c.group_id = delete_comment.group_id
      AND c.user_id = current_user_id;

  ELSE
    -- Hard delete
    DELETE FROM "Comments" c
    WHERE id = delete_comment.comment_id
      AND c.image_id = delete_comment.image_id
      AND c.group_id = delete_comment.group_id
      AND c.user_id = current_user_id;
  END IF;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'message',
      CASE
        WHEN has_children THEN 'Comment replaced by deletion marker'
        ELSE 'Comment deleted successfully'
      END
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

CREATE FUNCTION public.delete_image(image_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
BEGIN
  current_user_id := auth.uid();

  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM "Images" i
    WHERE i.id = delete_image.image_id
      AND i.uploaded_by = current_user_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Image not found or permission denied'
    );
  END IF;

  DELETE FROM "Reactions" r WHERE r.image_id = delete_image.image_id;
  DELETE FROM "Comments" c WHERE c.image_id = delete_image.image_id;
  DELETE FROM "ImageGroups" ig WHERE ig.image_id = delete_image.image_id;
  DELETE FROM "Images" i WHERE i.id = delete_image.image_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: edit_username(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.edit_username(new_username text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$BEGIN
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
END;$$;


--
-- Name: get_all_images(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_all_images() RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
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
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
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
END;$$;


--
-- Name: get_comment_notification(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_comment_notification(p_comment_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  uid UUID;
  r RECORD;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT c.group_id    AS group_id,
         c.image_id    AS image_id,
         g.name        AS group_name,
         c.user_id     AS commenter_id,
         cu.username   AS commenter_username,
         c.text        AS comment_text,
         i.uploaded_by AS uploader_id,
         uu.username   AS uploader_username
  INTO r
  FROM "Comments" c
  JOIN "Groups" g      ON g.id = c.group_id
  JOIN "Images" i      ON i.id = c.image_id
  LEFT JOIN "Users" cu ON cu.id = c.user_id
  LEFT JOIN "Users" uu ON uu.id = i.uploaded_by
  WHERE c.id = p_comment_id
    AND EXISTS (
      SELECT 1 FROM "Members" m
      WHERE m.group_id = c.group_id AND m.user_id = uid AND m.role != 'banned'
    );

  IF r IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not found or not a member');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'group_id', r.group_id,
    'image_id', r.image_id,
    'group_name', r.group_name,
    'commenter_id', r.commenter_id,
    'commenter_username', COALESCE(r.commenter_username, ''),
    'comment_text', COALESCE(r.comment_text, ''),
    'uploader_id', r.uploader_id,
    'uploader_username', COALESCE(r.uploader_username, '')
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_comments(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_comments(image_id uuid, group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id UUID;
  comments JSONB;
BEGIN
  current_user_id := auth.uid();
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM "Members" AS m
    WHERE m.user_id = current_user_id
      AND m.group_id = get_comments.group_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are not a member of this group');
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM "ImageGroups" AS ig
    WHERE ig.image_id = get_comments.image_id
      AND ig.group_id = get_comments.group_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Image does not belong to the specified group');
  END IF;
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', c.id,
        'user_id', c.user_id,
        'text', c.text,
        'created_at', c.created_at,
        'parent_id', c.parent_id
      )
      ORDER BY c.created_at ASC
    ),
    '[]'::jsonb
  )
  INTO comments
  FROM "Comments" AS c
  WHERE c.image_id = get_comments.image_id
    AND c.group_id = get_comments.group_id;
  RETURN jsonb_build_object('success', true, 'comments', comments);
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_group_details(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_group_details(group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
    group_record RECORD;
BEGIN
    SELECT id, created_at, name
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
            'name', group_record.name
        )
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_group_images(uuid, integer, timestamp with time zone, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_group_images(p_group_id uuid, p_limit integer DEFAULT NULL::integer, p_before_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  images_data jsonb;
  is_member boolean;
BEGIN
  current_user_id := auth.uid();
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM "Members"
    WHERE user_id = current_user_id
      AND group_id = p_group_id
      AND role <> 'banned'
  ) INTO is_member;

  IF NOT is_member THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are not a member of this group');
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id', sub.id,
      'uploaded_by', sub.uploaded_by,
      'uploaded_at', sub.uploaded_at
    ) ORDER BY sub.uploaded_at DESC, sub.id DESC
  )
  INTO images_data
  FROM (
    SELECT i.id, i.uploaded_by, COALESCE(ig.uploaded_at, i.created_at) AS uploaded_at
    FROM "Images" i
    JOIN "ImageGroups" ig ON i.id = ig.image_id
    WHERE ig.group_id = p_group_id
      AND (p_before_created_at IS NULL
           OR (COALESCE(ig.uploaded_at, i.created_at), i.id) < (p_before_created_at, p_before_id))
    ORDER BY COALESCE(ig.uploaded_at, i.created_at) DESC, i.id DESC
    LIMIT p_limit
  ) sub;

  RETURN jsonb_build_object('success', true, 'images', COALESCE(images_data, '[]'::jsonb));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_group_members(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_group_members(group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
    members JSONB;
BEGIN
    WITH member_data AS (
        SELECT
            m.user_id,
            m.role,
            get_username(m.user_id::text) AS username
        FROM "public"."Members" m
        WHERE m.group_id = get_group_members.group_id
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'user_id', user_id,
            'role', role,
            'username', username
        )
        ORDER BY username ASC
    )
    INTO members
    FROM member_data;

    IF members IS NULL THEN
        members := '[]'::jsonb;
    END IF;

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
    SET search_path TO 'public'
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
-- Name: get_image_comment_count(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_image_comment_count(p_image_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  comment_count integer;
BEGIN
  current_user_id := auth.uid();
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT COUNT(*)
  INTO comment_count
  FROM "Comments" c
  WHERE c.image_id = p_image_id
    AND EXISTS (
      SELECT 1 FROM "Members" m
      WHERE m.group_id = c.group_id
        AND m.user_id = current_user_id
        AND m.role != 'banned'
    );

  RETURN jsonb_build_object('success', true, 'count', comment_count);
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_image_comments_grouped(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_image_comments_grouped(p_image_id uuid, p_primary_group_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  result jsonb;
BEGIN
  current_user_id := auth.uid();
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT COALESCE(
    jsonb_agg(sub.grp ORDER BY sub.grp_is_primary DESC, sub.grp_name ASC),
    '[]'::jsonb
  )
  INTO result
  FROM (
    SELECT
      (g.id = p_primary_group_id) AS grp_is_primary,
      g.name AS grp_name,
      jsonb_build_object(
        'group_id', g.id,
        'group_name', g.name,
        'is_primary', (g.id = p_primary_group_id),
        'comments', COALESCE((
          SELECT jsonb_agg(
            jsonb_build_object(
              'id', c.id,
              'user_id', c.user_id,
              'text', c.text,
              'created_at', c.created_at,
              'parent_id', c.parent_id
            ) ORDER BY c.created_at ASC
          )
          FROM "Comments" c
          WHERE c.image_id = p_image_id
            AND c.group_id = g.id
        ), '[]'::jsonb)
      ) AS grp
    FROM "Groups" g
    WHERE EXISTS (
      SELECT 1 FROM "ImageGroups" ig
      WHERE ig.image_id = p_image_id
        AND ig.group_id = g.id
    )
    AND EXISTS (
      SELECT 1 FROM "Members" m
      WHERE m.group_id = g.id
        AND m.user_id = current_user_id
        AND m.role != 'banned'
    )
  ) sub;

  RETURN jsonb_build_object('success', true, 'groups', result);
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_image_details(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_image_details(image_id uuid) RETURNS TABLE(created_at timestamp with time zone, uploaded_by uuid, description text)
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$BEGIN
  RETURN QUERY
  SELECT i.created_at, i.uploaded_by, i.description
  FROM "Images" i
  WHERE i.id = image_id
  AND EXISTS (
    SELECT 1
    FROM "ImageGroups" ig
    JOIN "Members" m ON ig.group_id = m.group_id
    WHERE ig.image_id = i.id
      AND m.user_id = auth.uid()
      AND m.role != 'banned'
  );
END;$$;


--
-- Name: get_image_groups(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_image_groups(p_image_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  result jsonb;
BEGIN
  current_user_id := auth.uid();
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('group_id', g.id, 'group_name', g.name)
      ORDER BY g.name ASC
    ),
    '[]'::jsonb
  )
  INTO result
  FROM "Groups" g
  WHERE EXISTS (
    SELECT 1 FROM "ImageGroups" ig
    WHERE ig.image_id = p_image_id
      AND ig.group_id = g.id
  )
  AND EXISTS (
    SELECT 1 FROM "Members" m
    WHERE m.group_id = g.id
      AND m.user_id = current_user_id
      AND m.role != 'banned'
  );

  RETURN jsonb_build_object('success', true, 'groups', result);
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_image_notification(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_image_notification(p_image_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
  uid UUID;
  v_sender_id UUID;
  v_sender_username TEXT;
  v_description TEXT;
  v_groups JSONB;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT i.uploaded_by, u.username, i.description
  INTO v_sender_id, v_sender_username, v_description
  FROM "Images" i
  LEFT JOIN "Users" u ON u.id = i.uploaded_by
  WHERE i.id = p_image_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Image not found');
  END IF;

  -- Every group this image was sent to that the caller is a non-banned member of.
  SELECT jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name) ORDER BY g.name)
  INTO v_groups
  FROM "Groups" g
  JOIN "ImageGroups" ig ON ig.group_id = g.id AND ig.image_id = p_image_id
  WHERE EXISTS (
    SELECT 1 FROM "Members" m
    WHERE m.group_id = g.id AND m.user_id = uid AND m.role != 'banned'
  );

  IF v_groups IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not found or not a member');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'groups', v_groups,
    'sender_id', v_sender_id,
    'sender_username', COALESCE(v_sender_username, ''),
    'description', COALESCE(v_description, '')
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_image_reactions(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_image_reactions(p_image_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  result jsonb;
BEGIN
  current_user_id := auth.uid();
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('emoji', e.emoji, 'count', e.count, 'reacted_by_me', e.reacted_by_me)
      ORDER BY e.count DESC, e.emoji ASC
    ),
    '[]'::jsonb
  )
  INTO result
  FROM (
    SELECT r.emoji AS emoji, count(*) AS count,
           bool_or(r.user_id = current_user_id) AS reacted_by_me
    FROM "Reactions" r
    WHERE r.image_id = p_image_id
    GROUP BY r.emoji
  ) e;
  RETURN jsonb_build_object('success', true, 'reactions', result);
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_image_reactors(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_image_reactors(p_image_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  result jsonb;
BEGIN
  current_user_id := auth.uid();
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM "ImageGroups" ig
    JOIN "Members" m ON m.group_id = ig.group_id
    WHERE ig.image_id = p_image_id
      AND m.user_id = current_user_id
      AND m.role <> 'banned'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You cannot view this image');
  END IF;
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('emoji', r.emoji, 'user_id', r.user_id, 'username', COALESCE(u.username, ''))
      ORDER BY r.emoji ASC, u.username ASC
    ),
    '[]'::jsonb
  )
  INTO result
  FROM "Reactions" r
  LEFT JOIN "Users" u ON u.id = r.user_id
  WHERE r.image_id = p_image_id;
  RETURN jsonb_build_object('success', true, 'reactors', result);
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_latest_images(integer, text[], timestamp with time zone, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_latest_images(p_count integer DEFAULT 1, p_group_ids text[] DEFAULT NULL::text[], p_before_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  images_data jsonb;
BEGIN
  current_user_id := auth.uid();
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id', sub.id,
      'uploaded_by', sub.uploaded_by,
      'uploaded_at', sub.uploaded_at
    ) ORDER BY sub.uploaded_at DESC, sub.id DESC
  )
  INTO images_data
  FROM (
    SELECT i.id, i.uploaded_by,
           MIN(COALESCE(ig.uploaded_at, i.created_at)) AS uploaded_at
    FROM "Images" i
    JOIN "ImageGroups" ig ON i.id = ig.image_id
    JOIN "Members" m ON ig.group_id = m.group_id
    WHERE m.user_id = current_user_id
      AND m.role != 'banned'
      AND (p_group_ids IS NULL OR ig.group_id = ANY(p_group_ids::uuid[]))
    GROUP BY i.id, i.uploaded_by
    HAVING (p_before_created_at IS NULL
            OR (MIN(COALESCE(ig.uploaded_at, i.created_at)), i.id) < (p_before_created_at, p_before_id))
    ORDER BY MIN(COALESCE(ig.uploaded_at, i.created_at)) DESC, i.id DESC
    LIMIT p_count
  ) sub;

  RETURN jsonb_build_object('success', true, 'images', COALESCE(images_data, '[]'::jsonb));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_notify_group_comments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_notify_group_comments() RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  enabled_value boolean;
BEGIN
  current_user_id := auth.uid();

  -- Check authentication
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not authenticated'
    );
  END IF;

  -- Fetch the setting
  SELECT notify_group_comments
  INTO enabled_value
  FROM "Users"
  WHERE id = current_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not found'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'enabled', COALESCE(enabled_value, false)
  );
END;$$;


--
-- Name: get_notify_group_reactions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_notify_group_reactions() RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  enabled_value boolean;
BEGIN
  current_user_id := auth.uid();

  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT notify_group_reactions
  INTO enabled_value
  FROM "Users"
  WHERE id = current_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not found');
  END IF;

  RETURN jsonb_build_object('success', true, 'enabled', COALESCE(enabled_value, false));
END;$$;


--
-- Name: get_reaction_notification(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_reaction_notification(p_image_id uuid, p_reactor_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  uid uuid;
  v_reactor_username text;
  v_uploader_username text;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM "ImageGroups" ig
    JOIN "Members" m ON m.group_id = ig.group_id
    WHERE ig.image_id = p_image_id AND m.user_id = uid AND m.role <> 'banned'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not found or not a member');
  END IF;
  SELECT username INTO v_reactor_username FROM "Users" WHERE id = p_reactor_id;
  SELECT u.username INTO v_uploader_username
  FROM "Images" i
  JOIN "Users" u ON u.id = i.uploaded_by
  WHERE i.id = p_image_id;
  RETURN jsonb_build_object(
    'success', true,
    'image_id', p_image_id,
    'reactor_id', p_reactor_id,
    'reactor_username', COALESCE(v_reactor_username, ''),
    'uploader_username', COALESCE(v_uploader_username, '')
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_user_groups(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_groups() RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id UUID;
  user_groups JSONB;
BEGIN
  current_user_id := auth.uid();

  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  WITH group_data AS (
    SELECT
      g.id,
      g.name,
      g.invite_permission,
      gm.role,
      g.created_at,
      MAX(ig.uploaded_at) AS latest_image_at
    FROM "Groups" g
    JOIN "Members" gm ON g.id = gm.group_id
    LEFT JOIN "ImageGroups" ig ON ig.group_id = g.id
    WHERE gm.user_id = current_user_id
      AND gm.role <> 'banned'
    GROUP BY g.id, g.name, g.invite_permission, g.created_at, gm.role
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', id,
      'name', name,
      'invite_permission', invite_permission,
      'role', role,
      'created_at', created_at,
      'latest_image_at', latest_image_at
    )
    ORDER BY latest_image_at DESC NULLS LAST
  )
  INTO user_groups
  FROM group_data;

  RETURN jsonb_build_object('success', true, 'groups', COALESCE(user_groups, '[]'::jsonb));

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: get_username(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_username(user_id text) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'public'
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
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  INSERT INTO public."Users" (id, username)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'username', ''))
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;


--
-- Name: handle_storage_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_storage_delete() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $_$BEGIN
  -- Delete the corresponding record from the Images table
  DELETE FROM "Images"
  WHERE id = (
    SELECT uuid(
      regexp_replace(
        OLD.name,
        '^.*?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}).*$',
        '\1'
      )
    )
  )
  AND uploaded_by = auth.uid();

  RETURN OLD;
END;$_$;


--
-- Name: is_admin_or_owner(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin_or_owner(p_group_id uuid) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM "Members"
    WHERE group_id = p_group_id
    AND user_id = auth.uid()
    AND role IN ('owner','admin')
  );
END;$$;


--
-- Name: join_group_by_invite(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.join_group_by_invite(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  uid uuid := auth.uid();
  v_invite "GroupInvites";
  v_existing_role text;
BEGIN
  IF uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  -- Lock the invite row so concurrent joins can't blow past max_uses.
  SELECT * INTO v_invite
  FROM "GroupInvites"
  WHERE token = btrim(p_token)
  FOR UPDATE;

  IF v_invite.token IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid invite');
  END IF;

  IF v_invite.revoked
     OR (v_invite.expires_at IS NOT NULL AND v_invite.expires_at <= now())
     OR (v_invite.max_uses IS NOT NULL AND v_invite.uses >= v_invite.max_uses) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This invite is no longer valid');
  END IF;

  SELECT role INTO v_existing_role
  FROM "Members" WHERE group_id = v_invite.group_id AND user_id = uid;

  IF v_existing_role = 'banned' THEN
    RETURN jsonb_build_object('success', false, 'error', 'You have been banned from this group');
  ELSIF v_existing_role IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are already a member of this group');
  END IF;

  INSERT INTO "Members" (group_id, user_id, role)
  VALUES (v_invite.group_id, uid, 'member')
  ON CONFLICT (group_id, user_id) DO NOTHING;

  UPDATE "GroupInvites" SET uses = uses + 1 WHERE token = v_invite.token;

  RETURN jsonb_build_object('success', true, 'group_id', v_invite.group_id);
END;$$;


--
-- Name: leave_group(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.leave_group(group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
    deleted_count INT;
    user_role TEXT;
BEGIN
    -- Fetch role
    SELECT role INTO user_role
    FROM "public"."Members" m
    WHERE m.user_id = auth.uid()
      AND m.group_id = leave_group.group_id;

    -- User not in group
    IF user_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'You are not a member of this group'
        );
    END IF;

    -- Banned users cannot "leave"
    IF user_role = 'banned' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'You are banned from this group'
        );
    END IF;

    -- Owners cannot leave unless ownership is transferred
    IF user_role = 'owner' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Owners cannot leave. Transfer ownership first.'
        );
    END IF;

    -- Delete membership
    DELETE FROM "public"."Members" m
    WHERE m.user_id = auth.uid()
      AND m.group_id = leave_group.group_id
    RETURNING 1 INTO deleted_count;

    IF deleted_count IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Failed to remove user from group'
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'You have successfully left the group'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM
    );
END;$$;


--
-- Name: list_group_invites(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_group_invites(p_group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  uid uuid := auth.uid();
  v_role text;
  v_invites jsonb;
BEGIN
  IF uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT role INTO v_role
  FROM "Members" WHERE group_id = p_group_id AND user_id = uid;

  IF v_role IS NULL OR v_role NOT IN ('owner', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'You do not have permission to view invites');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'token', token,
           'created_by', created_by,
           'created_at', created_at,
           'expires_at', expires_at,
           'max_uses', max_uses,
           'uses', uses,
           'revoked', revoked
         ) ORDER BY created_at DESC), '[]'::jsonb)
  INTO v_invites
  FROM "GroupInvites" WHERE group_id = p_group_id;

  RETURN jsonb_build_object('success', true, 'invites', v_invites);
END;$$;


--
-- Name: manage_member_role(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.manage_member_role(group_id uuid, target_user_id uuid, action text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
    user_role TEXT;
    target_role TEXT;
BEGIN
    -- Ensure valid action
    IF action NOT IN ('promote_admin', 'demote', 'transfer_ownership') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid action');
    END IF;

    -- Get current user's role
    SELECT role INTO user_role
    FROM "Members" m
    WHERE m.group_id = manage_member_role.group_id AND m.user_id = auth.uid();

    IF user_role IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'You are not in this group');
    END IF;

    -- Get target user role
    SELECT role INTO target_role
    FROM "Members" m
    WHERE m.group_id = manage_member_role.group_id AND m.user_id = manage_member_role.target_user_id;

    IF target_role IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target user is not in this group');
    END IF;

    -- TRANSFER OWNERSHIP
    IF action = 'transfer_ownership' THEN
        IF user_role <> 'owner' THEN
            RETURN jsonb_build_object('success', false, 'error', 'Only the owner can transfer ownership');
        END IF;

        -- Promote target to owner
        UPDATE "Members" m
        SET role = 'owner'
        WHERE m.group_id = manage_member_role.group_id AND m.user_id = manage_member_role.target_user_id;

        -- Demote current owner to admin
        UPDATE "Members" m
        SET role = 'admin'
        WHERE m.group_id = manage_member_role.group_id AND m.user_id = auth.uid();

        RETURN jsonb_build_object('success', true, 'role', 'owner');
    END IF;

    -- PROMOTE TO ADMIN
    IF action = 'promote_admin' THEN
        IF user_role NOT IN ('owner', 'admin') THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Only admins or owners can promote'
            );
        END IF;

        UPDATE "Members" m
        SET role = 'admin'
        WHERE m.group_id = manage_member_role.group_id AND m.user_id = manage_member_role.target_user_id;

        RETURN jsonb_build_object('success', true, 'role', 'admin');
    END IF;

    -- DEMOTE
    IF action = 'demote' THEN
        IF user_role NOT IN ('owner', 'admin') THEN
            RETURN jsonb_build_object('success', false, 'error', 'Only admins or owners can demote');
        END IF;

        -- Prevent demoting owner
        IF target_role = 'owner' THEN
            RETURN jsonb_build_object('success', false, 'error', 'Cannot demote the owner');
        END IF;

        -- Admins cannot demote other admins
        IF user_role = 'admin' AND target_role = 'admin' THEN
            RETURN jsonb_build_object('success', false, 'error', 'Admins cannot demote other admins');
        END IF;

        UPDATE "Members" m
        SET role = 'member'
        WHERE m.group_id = manage_member_role.group_id AND m.user_id = manage_member_role.target_user_id;

        RETURN jsonb_build_object('success', true, 'role', 'member');
    END IF;

    RETURN jsonb_build_object('success', false, 'error', 'Unknown error');
END;$$;


--
-- Name: register_fcm_token(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_fcm_token(p_fcm_token text, p_username text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  INSERT INTO public."Users" (id, fcm_token, username)
  VALUES (auth.uid(), p_fcm_token, COALESCE(p_username, ''))
  ON CONFLICT (id) DO UPDATE
    SET fcm_token = EXCLUDED.fcm_token,
        username = CASE WHEN p_username IS NOT NULL THEN EXCLUDED.username ELSE "Users".username END;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: register_uploaded_image(uuid, text[], text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_uploaded_image(image_id uuid, group_ids text[], image_description text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$declare
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
        and m.role <> 'banned'
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
end;$$;


--
-- Name: remove_group(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.remove_group(group_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
    user_role_check TEXT;
    group_deleted INT;
BEGIN

    -- Get the user role in that group
    SELECT role INTO user_role_check
    FROM "public"."Members" m
    WHERE m.user_id = auth.uid() AND m.group_id = remove_group.group_id;

    -- If the user is not in the group
    IF user_role_check IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'You are not a member of this group'
        );
    END IF;

    -- If the user is not an owner, deny deletion
    IF user_role_check != 'owner' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only the owner can delete the group'
        );
    END IF;

    -- Delete the group (and Members by cascade)
    DELETE FROM "public"."Groups" g
    WHERE g.id = remove_group.group_id;

    GET DIAGNOSTICS group_deleted = ROW_COUNT;

    IF group_deleted = 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Failed to delete group'
        );
    END IF;

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
-- Name: remove_image_from_groups(uuid, uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.remove_image_from_groups(p_image_id uuid, p_group_ids uuid[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  is_uploader boolean;
  allowed_group_ids uuid[];
  remaining int;
  fully_deleted boolean := false;
BEGIN
  current_user_id := auth.uid();

  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM "Images" i
    WHERE i.id = p_image_id
      AND i.uploaded_by = current_user_id
  ) INTO is_uploader;

  IF is_uploader THEN
    allowed_group_ids := p_group_ids;
  ELSE
    -- Owners and admins can remove anyone's photo from the groups they moderate
    SELECT coalesce(array_agg(g), '{}'::uuid[])
      INTO allowed_group_ids
      FROM unnest(p_group_ids) AS g
     WHERE public.is_admin_or_owner(g);
  END IF;

  IF cardinality(allowed_group_ids) = 0 OR NOT EXISTS (
    SELECT 1 FROM "Images" i WHERE i.id = p_image_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Image not found or permission denied'
    );
  END IF;

  DELETE FROM "Comments"
   WHERE image_id = p_image_id AND group_id = ANY (allowed_group_ids);
  DELETE FROM "ImageGroups"
   WHERE image_id = p_image_id AND group_id = ANY (allowed_group_ids);

  SELECT count(*) INTO remaining
    FROM "ImageGroups" WHERE image_id = p_image_id;

  IF remaining = 0 THEN
    DELETE FROM "Reactions" WHERE image_id = p_image_id;
    DELETE FROM "Comments" WHERE image_id = p_image_id;
    DELETE FROM "Images" WHERE id = p_image_id;
    fully_deleted := true;
  END IF;

  RETURN jsonb_build_object('success', true, 'fully_deleted', fully_deleted);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: request_image_uuid(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.request_image_uuid() RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$declare
  current_user_id uuid;
  new_id uuid;
begin
  current_user_id := auth.uid();
  if current_user_id is null then
    return jsonb_build_object('success', false, 'error', 'User not authenticated');
  end if;

  -- Generate UUID
  new_id := gen_random_uuid();

  return jsonb_build_object('success', true, 'image_id', new_id);
exception
  when others then
    return jsonb_build_object('success', false, 'error', sqlerrm);
end;$$;


--
-- Name: revoke_group_invite(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revoke_group_invite(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
  uid uuid := auth.uid();
  v_group_id uuid;
  v_created_by uuid;
  v_role text;
BEGIN
  IF uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  SELECT group_id, created_by INTO v_group_id, v_created_by
  FROM "GroupInvites" WHERE token = btrim(p_token);

  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid invite');
  END IF;

  SELECT role INTO v_role
  FROM "Members" WHERE group_id = v_group_id AND user_id = uid;

  IF NOT (v_created_by = uid OR v_role IN ('owner', 'admin')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You do not have permission to revoke this invite');
  END IF;

  UPDATE "GroupInvites" SET revoked = true WHERE token = btrim(p_token);

  RETURN jsonb_build_object('success', true);
END;$$;


--
-- Name: set_group_invite_permission(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_group_invite_permission(p_group_id uuid, p_permission text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  uid uuid := auth.uid();
  v_role text;
BEGIN
  IF uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;

  IF p_permission NOT IN ('owner', 'admin', 'everyone') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid permission value');
  END IF;

  SELECT role INTO v_role
  FROM "Members" WHERE group_id = p_group_id AND user_id = uid;

  IF v_role IS DISTINCT FROM 'owner' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only the group owner can change invite permissions');
  END IF;

  UPDATE "Groups" SET invite_permission = p_permission WHERE id = p_group_id;

  RETURN jsonb_build_object('success', true, 'invite_permission', p_permission);
END;$$;


--
-- Name: set_notify_group_comments(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_notify_group_comments(enabled boolean) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
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

    UPDATE "Users"
    SET notify_group_comments = enabled
    WHERE id = current_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'User not found'
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'notify_group_comments', enabled
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;$$;


--
-- Name: set_notify_group_reactions(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_notify_group_reactions(enabled boolean) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
    current_user_id UUID;
BEGIN
    current_user_id := auth.uid();

    IF current_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
    END IF;

    UPDATE "Users"
    SET notify_group_reactions = enabled
    WHERE id = current_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'User not found');
    END IF;

    RETURN jsonb_build_object('success', true, 'notify_group_reactions', enabled);

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: toggle_reaction(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.toggle_reaction(p_image_id uuid, p_emoji text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id uuid;
  deleted_count integer;
BEGIN
  current_user_id := auth.uid();
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;
  IF p_emoji IS NULL OR char_length(p_emoji) = 0 OR char_length(p_emoji) > 16 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid emoji');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM "ImageGroups" ig
    JOIN "Members" m ON m.group_id = ig.group_id
    WHERE ig.image_id = p_image_id
      AND m.user_id = current_user_id
      AND m.role <> 'banned'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You cannot react to this image');
  END IF;
  DELETE FROM "Reactions" r
  WHERE r.user_id = current_user_id AND r.image_id = p_image_id AND r.emoji = p_emoji;
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  IF deleted_count > 0 THEN
    RETURN jsonb_build_object('success', true, 'reacted', false);
  END IF;
  INSERT INTO "Reactions" (user_id, image_id, emoji)
  VALUES (current_user_id, p_image_id, p_emoji);
  RETURN jsonb_build_object('success', true, 'reacted', true);
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: unban_user(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.unban_user(group_id uuid, target_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  caller_role TEXT;
  target_role TEXT;
  rows_deleted INT;
BEGIN
  -- Verify caller role
  SELECT role INTO caller_role
  FROM "Members" m
  WHERE m.group_id = unban_user.group_id
  AND m.user_id = auth.uid();

  IF caller_role IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'You are not a member of this group'
    );
  END IF;

  IF caller_role NOT IN ('owner','admin') THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Only admins or owners can unban users'
    );
  END IF;

  -- Verify target user exists
  SELECT role INTO target_role
  FROM "Members" m
  WHERE m.group_id = unban_user.group_id
  AND m.user_id = unban_user.target_user_id;

  IF target_role IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Target user is not a member of this group'
    );
  END IF;

  -- Ensure target user is banned
  IF target_role <> 'banned' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User is not banned'
    );
  END IF;

  -- Perform unban
  DELETE FROM "Members" m
  WHERE m.group_id = unban_user.group_id
  AND m.user_id = unban_user.target_user_id
  RETURNING 1 INTO rows_deleted;

  IF rows_deleted IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Failed to unban user'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'User unbanned successfully'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;$$;


--
-- Name: update_comment(uuid, uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_comment(comment_id uuid, image_id uuid, group_id uuid, text text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$DECLARE
  current_user_id UUID;
BEGIN
  current_user_id := auth.uid();
  IF current_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'User not authenticated');
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM "Members" m
    WHERE m.user_id = current_user_id
      AND m.group_id = update_comment.group_id
      AND m.role <> 'banned'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are not a member of this group');
  END IF;
  UPDATE "Comments" c
  SET text = update_comment.text
  WHERE c.id = update_comment.comment_id
    AND c.image_id = update_comment.image_id
    AND c.group_id = update_comment.group_id
    AND c.user_id = current_user_id;
  IF FOUND THEN
    RETURN jsonb_build_object('success', true, 'message', 'Comment updated successfully');
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'No comment found to update or permission denied');
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;$$;


--
-- Name: update_group_name(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_group_name(group_id uuid, new_name text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
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
-- Name: allow_any_operation(text[]); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.allow_any_operation(expected_operations text[]) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  WITH current_operation AS (
    SELECT storage.operation() AS raw_operation
  ),
  normalized AS (
    SELECT CASE
      WHEN raw_operation LIKE 'storage.%' THEN substr(raw_operation, 9)
      ELSE raw_operation
    END AS current_operation
    FROM current_operation
  )
  SELECT EXISTS (
    SELECT 1
    FROM normalized n
    CROSS JOIN LATERAL unnest(expected_operations) AS expected_operation
    WHERE expected_operation IS NOT NULL
      AND expected_operation <> ''
      AND n.current_operation = CASE
        WHEN expected_operation LIKE 'storage.%' THEN substr(expected_operation, 9)
        ELSE expected_operation
      END
  );
$$;


--
-- Name: allow_only_operation(text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.allow_only_operation(expected_operation text) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  WITH current_operation AS (
    SELECT storage.operation() AS raw_operation
  ),
  normalized AS (
    SELECT
      CASE
        WHEN raw_operation LIKE 'storage.%' THEN substr(raw_operation, 9)
        ELSE raw_operation
      END AS current_operation,
      CASE
        WHEN expected_operation LIKE 'storage.%' THEN substr(expected_operation, 9)
        ELSE expected_operation
      END AS requested_operation
    FROM current_operation
  )
  SELECT CASE
    WHEN requested_operation IS NULL OR requested_operation = '' THEN FALSE
    ELSE COALESCE(current_operation = requested_operation, FALSE)
  END
  FROM normalized;
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
    -- Split on "/" to get path segments
    SELECT string_to_array(name, '/') INTO _parts;
    -- Get the last path segment (the actual filename)
    SELECT _parts[array_length(_parts, 1)] INTO _filename;
    -- Extract extension: reverse, split on '.', then reverse again
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
-- Name: get_common_prefix(text, text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.get_common_prefix(p_key text, p_prefix text, p_delimiter text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
SELECT CASE
    WHEN position(p_delimiter IN substring(p_key FROM length(p_prefix) + 1)) > 0
    THEN left(p_key, length(p_prefix) + position(p_delimiter IN substring(p_key FROM length(p_prefix) + 1)))
    ELSE NULL
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
        select sum((metadata->>'size')::bigint)::bigint as size, obj.bucket_id
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
-- Name: list_objects_with_delimiter(text, text, text, integer, text, text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.list_objects_with_delimiter(_bucket_id text, prefix_param text, delimiter_param text, max_keys integer DEFAULT 100, start_after text DEFAULT ''::text, next_token text DEFAULT ''::text, sort_order text DEFAULT 'asc'::text) RETURNS TABLE(name text, id uuid, metadata jsonb, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone)
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_peek_name TEXT;
    v_current RECORD;
    v_common_prefix TEXT;

    -- Configuration
    v_is_asc BOOLEAN;
    v_prefix TEXT;
    v_start TEXT;
    v_upper_bound TEXT;
    v_file_batch_size INT;

    -- Seek state
    v_next_seek TEXT;
    v_count INT := 0;

    -- Dynamic SQL for batch query only
    v_batch_query TEXT;

BEGIN
    -- ========================================================================
    -- INITIALIZATION
    -- ========================================================================
    v_is_asc := lower(coalesce(sort_order, 'asc')) = 'asc';
    v_prefix := coalesce(prefix_param, '');
    v_start := CASE WHEN coalesce(next_token, '') <> '' THEN next_token ELSE coalesce(start_after, '') END;
    v_file_batch_size := LEAST(GREATEST(max_keys * 2, 100), 1000);

    -- Calculate upper bound for prefix filtering (bytewise, using COLLATE "C")
    IF v_prefix = '' THEN
        v_upper_bound := NULL;
    ELSIF right(v_prefix, 1) = delimiter_param THEN
        v_upper_bound := left(v_prefix, -1) || chr(ascii(delimiter_param) + 1);
    ELSE
        v_upper_bound := left(v_prefix, -1) || chr(ascii(right(v_prefix, 1)) + 1);
    END IF;

    -- Build batch query (dynamic SQL - called infrequently, amortized over many rows)
    IF v_is_asc THEN
        IF v_upper_bound IS NOT NULL THEN
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND o.name COLLATE "C" >= $2 ' ||
                'AND o.name COLLATE "C" < $3 ORDER BY o.name COLLATE "C" ASC LIMIT $4';
        ELSE
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND o.name COLLATE "C" >= $2 ' ||
                'ORDER BY o.name COLLATE "C" ASC LIMIT $4';
        END IF;
    ELSE
        IF v_upper_bound IS NOT NULL THEN
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND o.name COLLATE "C" < $2 ' ||
                'AND o.name COLLATE "C" >= $3 ORDER BY o.name COLLATE "C" DESC LIMIT $4';
        ELSE
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND o.name COLLATE "C" < $2 ' ||
                'ORDER BY o.name COLLATE "C" DESC LIMIT $4';
        END IF;
    END IF;

    -- ========================================================================
    -- SEEK INITIALIZATION: Determine starting position
    -- ========================================================================
    IF v_start = '' THEN
        IF v_is_asc THEN
            v_next_seek := v_prefix;
        ELSE
            -- DESC without cursor: find the last item in range
            IF v_upper_bound IS NOT NULL THEN
                SELECT o.name INTO v_next_seek FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" >= v_prefix AND o.name COLLATE "C" < v_upper_bound
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            ELSIF v_prefix <> '' THEN
                SELECT o.name INTO v_next_seek FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" >= v_prefix
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            ELSE
                SELECT o.name INTO v_next_seek FROM storage.objects o
                WHERE o.bucket_id = _bucket_id
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            END IF;

            IF v_next_seek IS NOT NULL THEN
                v_next_seek := v_next_seek || delimiter_param;
            ELSE
                RETURN;
            END IF;
        END IF;
    ELSE
        -- Cursor provided: determine if it refers to a folder or leaf
        IF EXISTS (
            SELECT 1 FROM storage.objects o
            WHERE o.bucket_id = _bucket_id
              AND o.name COLLATE "C" LIKE v_start || delimiter_param || '%'
            LIMIT 1
        ) THEN
            -- Cursor refers to a folder
            IF v_is_asc THEN
                v_next_seek := v_start || chr(ascii(delimiter_param) + 1);
            ELSE
                v_next_seek := v_start || delimiter_param;
            END IF;
        ELSE
            -- Cursor refers to a leaf object
            IF v_is_asc THEN
                v_next_seek := v_start || delimiter_param;
            ELSE
                v_next_seek := v_start;
            END IF;
        END IF;
    END IF;

    -- ========================================================================
    -- MAIN LOOP: Hybrid peek-then-batch algorithm
    -- Uses STATIC SQL for peek (hot path) and DYNAMIC SQL for batch
    -- ========================================================================
    LOOP
        EXIT WHEN v_count >= max_keys;

        -- STEP 1: PEEK using STATIC SQL (plan cached, very fast)
        IF v_is_asc THEN
            IF v_upper_bound IS NOT NULL THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" >= v_next_seek AND o.name COLLATE "C" < v_upper_bound
                ORDER BY o.name COLLATE "C" ASC LIMIT 1;
            ELSE
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" >= v_next_seek
                ORDER BY o.name COLLATE "C" ASC LIMIT 1;
            END IF;
        ELSE
            IF v_upper_bound IS NOT NULL THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" < v_next_seek AND o.name COLLATE "C" >= v_prefix
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            ELSIF v_prefix <> '' THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" < v_next_seek AND o.name COLLATE "C" >= v_prefix
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            ELSE
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = _bucket_id AND o.name COLLATE "C" < v_next_seek
                ORDER BY o.name COLLATE "C" DESC LIMIT 1;
            END IF;
        END IF;

        EXIT WHEN v_peek_name IS NULL;

        -- STEP 2: Check if this is a FOLDER or FILE
        v_common_prefix := storage.get_common_prefix(v_peek_name, v_prefix, delimiter_param);

        IF v_common_prefix IS NOT NULL THEN
            -- FOLDER: Emit and skip to next folder (no heap access needed)
            name := rtrim(v_common_prefix, delimiter_param);
            id := NULL;
            updated_at := NULL;
            created_at := NULL;
            last_accessed_at := NULL;
            metadata := NULL;
            RETURN NEXT;
            v_count := v_count + 1;

            -- Advance seek past the folder range
            IF v_is_asc THEN
                v_next_seek := left(v_common_prefix, -1) || chr(ascii(delimiter_param) + 1);
            ELSE
                v_next_seek := v_common_prefix;
            END IF;
        ELSE
            -- FILE: Batch fetch using DYNAMIC SQL (overhead amortized over many rows)
            -- For ASC: upper_bound is the exclusive upper limit (< condition)
            -- For DESC: prefix is the inclusive lower limit (>= condition)
            FOR v_current IN EXECUTE v_batch_query USING _bucket_id, v_next_seek,
                CASE WHEN v_is_asc THEN COALESCE(v_upper_bound, v_prefix) ELSE v_prefix END, v_file_batch_size
            LOOP
                v_common_prefix := storage.get_common_prefix(v_current.name, v_prefix, delimiter_param);

                IF v_common_prefix IS NOT NULL THEN
                    -- Hit a folder: exit batch, let peek handle it
                    v_next_seek := v_current.name;
                    EXIT;
                END IF;

                -- Emit file
                name := v_current.name;
                id := v_current.id;
                updated_at := v_current.updated_at;
                created_at := v_current.created_at;
                last_accessed_at := v_current.last_accessed_at;
                metadata := v_current.metadata;
                RETURN NEXT;
                v_count := v_count + 1;

                -- Advance seek past this file
                IF v_is_asc THEN
                    v_next_seek := v_current.name || delimiter_param;
                ELSE
                    v_next_seek := v_current.name;
                END IF;

                EXIT WHEN v_count >= max_keys;
            END LOOP;
        END IF;
    END LOOP;
END;
$_$;


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
-- Name: protect_delete(); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.protect_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Check if storage.allow_delete_query is set to 'true'
    IF COALESCE(current_setting('storage.allow_delete_query', true), 'false') != 'true' THEN
        RAISE EXCEPTION 'Direct deletion from storage tables is not allowed. Use the Storage API instead.'
            USING HINT = 'This prevents accidental data loss from orphaned objects.',
                  ERRCODE = '42501';
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: search(text, text, integer, integer, integer, text, text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.search(prefix text, bucketname text, limits integer DEFAULT 100, levels integer DEFAULT 1, offsets integer DEFAULT 0, search text DEFAULT ''::text, sortcolumn text DEFAULT 'name'::text, sortorder text DEFAULT 'asc'::text) RETURNS TABLE(name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, metadata jsonb)
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_peek_name TEXT;
    v_current RECORD;
    v_common_prefix TEXT;
    v_delimiter CONSTANT TEXT := '/';

    -- Configuration
    v_limit INT;
    v_prefix TEXT;
    v_prefix_lower TEXT;
    v_is_asc BOOLEAN;
    v_order_by TEXT;
    v_sort_order TEXT;
    v_upper_bound TEXT;
    v_file_batch_size INT;

    -- Dynamic SQL for batch query only
    v_batch_query TEXT;

    -- Seek state
    v_next_seek TEXT;
    v_count INT := 0;
    v_skipped INT := 0;
BEGIN
    -- ========================================================================
    -- INITIALIZATION
    -- ========================================================================
    v_limit := LEAST(coalesce(limits, 100), 1500);
    v_prefix := coalesce(prefix, '') || coalesce(search, '');
    v_prefix_lower := lower(v_prefix);
    v_is_asc := lower(coalesce(sortorder, 'asc')) = 'asc';
    v_file_batch_size := LEAST(GREATEST(v_limit * 2, 100), 1000);

    -- Validate sort column
    CASE lower(coalesce(sortcolumn, 'name'))
        WHEN 'name' THEN v_order_by := 'name';
        WHEN 'updated_at' THEN v_order_by := 'updated_at';
        WHEN 'created_at' THEN v_order_by := 'created_at';
        WHEN 'last_accessed_at' THEN v_order_by := 'last_accessed_at';
        ELSE v_order_by := 'name';
    END CASE;

    v_sort_order := CASE WHEN v_is_asc THEN 'asc' ELSE 'desc' END;

    -- ========================================================================
    -- NON-NAME SORTING: Use path_tokens approach (unchanged)
    -- ========================================================================
    IF v_order_by != 'name' THEN
        RETURN QUERY EXECUTE format(
            $sql$
            WITH folders AS (
                SELECT path_tokens[$1] AS folder
                FROM storage.objects
                WHERE objects.name ILIKE $2 || '%%'
                  AND bucket_id = $3
                  AND array_length(objects.path_tokens, 1) <> $1
                GROUP BY folder
                ORDER BY folder %s
            )
            (SELECT folder AS "name",
                   NULL::uuid AS id,
                   NULL::timestamptz AS updated_at,
                   NULL::timestamptz AS created_at,
                   NULL::timestamptz AS last_accessed_at,
                   NULL::jsonb AS metadata FROM folders)
            UNION ALL
            (SELECT path_tokens[$1] AS "name",
                   id, updated_at, created_at, last_accessed_at, metadata
             FROM storage.objects
             WHERE objects.name ILIKE $2 || '%%'
               AND bucket_id = $3
               AND array_length(objects.path_tokens, 1) = $1
             ORDER BY %I %s)
            LIMIT $4 OFFSET $5
            $sql$, v_sort_order, v_order_by, v_sort_order
        ) USING levels, v_prefix, bucketname, v_limit, offsets;
        RETURN;
    END IF;

    -- ========================================================================
    -- NAME SORTING: Hybrid skip-scan with batch optimization
    -- ========================================================================

    -- Calculate upper bound for prefix filtering
    IF v_prefix_lower = '' THEN
        v_upper_bound := NULL;
    ELSIF right(v_prefix_lower, 1) = v_delimiter THEN
        v_upper_bound := left(v_prefix_lower, -1) || chr(ascii(v_delimiter) + 1);
    ELSE
        v_upper_bound := left(v_prefix_lower, -1) || chr(ascii(right(v_prefix_lower, 1)) + 1);
    END IF;

    -- Build batch query (dynamic SQL - called infrequently, amortized over many rows)
    IF v_is_asc THEN
        IF v_upper_bound IS NOT NULL THEN
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND lower(o.name) COLLATE "C" >= $2 ' ||
                'AND lower(o.name) COLLATE "C" < $3 ORDER BY lower(o.name) COLLATE "C" ASC LIMIT $4';
        ELSE
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND lower(o.name) COLLATE "C" >= $2 ' ||
                'ORDER BY lower(o.name) COLLATE "C" ASC LIMIT $4';
        END IF;
    ELSE
        IF v_upper_bound IS NOT NULL THEN
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND lower(o.name) COLLATE "C" < $2 ' ||
                'AND lower(o.name) COLLATE "C" >= $3 ORDER BY lower(o.name) COLLATE "C" DESC LIMIT $4';
        ELSE
            v_batch_query := 'SELECT o.name, o.id, o.updated_at, o.created_at, o.last_accessed_at, o.metadata ' ||
                'FROM storage.objects o WHERE o.bucket_id = $1 AND lower(o.name) COLLATE "C" < $2 ' ||
                'ORDER BY lower(o.name) COLLATE "C" DESC LIMIT $4';
        END IF;
    END IF;

    -- Initialize seek position
    IF v_is_asc THEN
        v_next_seek := v_prefix_lower;
    ELSE
        -- DESC: find the last item in range first (static SQL)
        IF v_upper_bound IS NOT NULL THEN
            SELECT o.name INTO v_peek_name FROM storage.objects o
            WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" >= v_prefix_lower AND lower(o.name) COLLATE "C" < v_upper_bound
            ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
        ELSIF v_prefix_lower <> '' THEN
            SELECT o.name INTO v_peek_name FROM storage.objects o
            WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" >= v_prefix_lower
            ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
        ELSE
            SELECT o.name INTO v_peek_name FROM storage.objects o
            WHERE o.bucket_id = bucketname
            ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
        END IF;

        IF v_peek_name IS NOT NULL THEN
            v_next_seek := lower(v_peek_name) || v_delimiter;
        ELSE
            RETURN;
        END IF;
    END IF;

    -- ========================================================================
    -- MAIN LOOP: Hybrid peek-then-batch algorithm
    -- Uses STATIC SQL for peek (hot path) and DYNAMIC SQL for batch
    -- ========================================================================
    LOOP
        EXIT WHEN v_count >= v_limit;

        -- STEP 1: PEEK using STATIC SQL (plan cached, very fast)
        IF v_is_asc THEN
            IF v_upper_bound IS NOT NULL THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" >= v_next_seek AND lower(o.name) COLLATE "C" < v_upper_bound
                ORDER BY lower(o.name) COLLATE "C" ASC LIMIT 1;
            ELSE
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" >= v_next_seek
                ORDER BY lower(o.name) COLLATE "C" ASC LIMIT 1;
            END IF;
        ELSE
            IF v_upper_bound IS NOT NULL THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" < v_next_seek AND lower(o.name) COLLATE "C" >= v_prefix_lower
                ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
            ELSIF v_prefix_lower <> '' THEN
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" < v_next_seek AND lower(o.name) COLLATE "C" >= v_prefix_lower
                ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
            ELSE
                SELECT o.name INTO v_peek_name FROM storage.objects o
                WHERE o.bucket_id = bucketname AND lower(o.name) COLLATE "C" < v_next_seek
                ORDER BY lower(o.name) COLLATE "C" DESC LIMIT 1;
            END IF;
        END IF;

        EXIT WHEN v_peek_name IS NULL;

        -- STEP 2: Check if this is a FOLDER or FILE
        v_common_prefix := storage.get_common_prefix(lower(v_peek_name), v_prefix_lower, v_delimiter);

        IF v_common_prefix IS NOT NULL THEN
            -- FOLDER: Handle offset, emit if needed, skip to next folder
            IF v_skipped < offsets THEN
                v_skipped := v_skipped + 1;
            ELSE
                name := split_part(rtrim(storage.get_common_prefix(v_peek_name, v_prefix, v_delimiter), v_delimiter), v_delimiter, levels);
                id := NULL;
                updated_at := NULL;
                created_at := NULL;
                last_accessed_at := NULL;
                metadata := NULL;
                RETURN NEXT;
                v_count := v_count + 1;
            END IF;

            -- Advance seek past the folder range
            IF v_is_asc THEN
                v_next_seek := lower(left(v_common_prefix, -1)) || chr(ascii(v_delimiter) + 1);
            ELSE
                v_next_seek := lower(v_common_prefix);
            END IF;
        ELSE
            -- FILE: Batch fetch using DYNAMIC SQL (overhead amortized over many rows)
            -- For ASC: upper_bound is the exclusive upper limit (< condition)
            -- For DESC: prefix_lower is the inclusive lower limit (>= condition)
            FOR v_current IN EXECUTE v_batch_query
                USING bucketname, v_next_seek,
                    CASE WHEN v_is_asc THEN COALESCE(v_upper_bound, v_prefix_lower) ELSE v_prefix_lower END, v_file_batch_size
            LOOP
                v_common_prefix := storage.get_common_prefix(lower(v_current.name), v_prefix_lower, v_delimiter);

                IF v_common_prefix IS NOT NULL THEN
                    -- Hit a folder: exit batch, let peek handle it
                    v_next_seek := lower(v_current.name);
                    EXIT;
                END IF;

                -- Handle offset skipping
                IF v_skipped < offsets THEN
                    v_skipped := v_skipped + 1;
                ELSE
                    -- Emit file
                    name := split_part(v_current.name, v_delimiter, levels);
                    id := v_current.id;
                    updated_at := v_current.updated_at;
                    created_at := v_current.created_at;
                    last_accessed_at := v_current.last_accessed_at;
                    metadata := v_current.metadata;
                    RETURN NEXT;
                    v_count := v_count + 1;
                END IF;

                -- Advance seek past this file
                IF v_is_asc THEN
                    v_next_seek := lower(v_current.name) || v_delimiter;
                ELSE
                    v_next_seek := lower(v_current.name);
                END IF;

                EXIT WHEN v_count >= v_limit;
            END LOOP;
        END IF;
    END LOOP;
END;
$_$;


--
-- Name: search_by_timestamp(text, text, integer, integer, text, text, text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.search_by_timestamp(p_prefix text, p_bucket_id text, p_limit integer, p_level integer, p_start_after text, p_sort_order text, p_sort_column text, p_sort_column_after text) RETURNS TABLE(key text, name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, metadata jsonb)
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_cursor_op text;
    v_query text;
    v_prefix text;
BEGIN
    v_prefix := coalesce(p_prefix, '');

    IF p_sort_order = 'asc' THEN
        v_cursor_op := '>';
    ELSE
        v_cursor_op := '<';
    END IF;

    v_query := format($sql$
        WITH raw_objects AS (
            SELECT
                o.name AS obj_name,
                o.id AS obj_id,
                o.updated_at AS obj_updated_at,
                o.created_at AS obj_created_at,
                o.last_accessed_at AS obj_last_accessed_at,
                o.metadata AS obj_metadata,
                storage.get_common_prefix(o.name, $1, '/') AS common_prefix
            FROM storage.objects o
            WHERE o.bucket_id = $2
              AND o.name COLLATE "C" LIKE $1 || '%%'
        ),
        -- Aggregate common prefixes (folders)
        -- Both created_at and updated_at use MIN(obj_created_at) to match the old prefixes table behavior
        aggregated_prefixes AS (
            SELECT
                rtrim(common_prefix, '/') AS name,
                NULL::uuid AS id,
                MIN(obj_created_at) AS updated_at,
                MIN(obj_created_at) AS created_at,
                NULL::timestamptz AS last_accessed_at,
                NULL::jsonb AS metadata,
                TRUE AS is_prefix
            FROM raw_objects
            WHERE common_prefix IS NOT NULL
            GROUP BY common_prefix
        ),
        leaf_objects AS (
            SELECT
                obj_name AS name,
                obj_id AS id,
                obj_updated_at AS updated_at,
                obj_created_at AS created_at,
                obj_last_accessed_at AS last_accessed_at,
                obj_metadata AS metadata,
                FALSE AS is_prefix
            FROM raw_objects
            WHERE common_prefix IS NULL
        ),
        combined AS (
            SELECT * FROM aggregated_prefixes
            UNION ALL
            SELECT * FROM leaf_objects
        ),
        filtered AS (
            SELECT *
            FROM combined
            WHERE (
                $5 = ''
                OR ROW(
                    date_trunc('milliseconds', %I),
                    name COLLATE "C"
                ) %s ROW(
                    COALESCE(NULLIF($6, '')::timestamptz, 'epoch'::timestamptz),
                    $5
                )
            )
        )
        SELECT
            split_part(name, '/', $3) AS key,
            name,
            id,
            updated_at,
            created_at,
            last_accessed_at,
            metadata
        FROM filtered
        ORDER BY
            COALESCE(date_trunc('milliseconds', %I), 'epoch'::timestamptz) %s,
            name COLLATE "C" %s
        LIMIT $4
    $sql$,
        p_sort_column,
        v_cursor_op,
        p_sort_column,
        p_sort_order,
        p_sort_order
    );

    RETURN QUERY EXECUTE v_query
    USING v_prefix, p_bucket_id, p_level, p_limit, p_start_after, p_sort_column_after;
END;
$_$;


--
-- Name: search_v2(text, text, integer, integer, text, text, text, text); Type: FUNCTION; Schema: storage; Owner: -
--

CREATE FUNCTION storage.search_v2(prefix text, bucket_name text, limits integer DEFAULT 100, levels integer DEFAULT 1, start_after text DEFAULT ''::text, sort_order text DEFAULT 'asc'::text, sort_column text DEFAULT 'name'::text, sort_column_after text DEFAULT ''::text) RETURNS TABLE(key text, name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, metadata jsonb)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_sort_col text;
    v_sort_ord text;
    v_limit int;
BEGIN
    -- Cap limit to maximum of 1500 records
    v_limit := LEAST(coalesce(limits, 100), 1500);

    -- Validate and normalize sort_order
    v_sort_ord := lower(coalesce(sort_order, 'asc'));
    IF v_sort_ord NOT IN ('asc', 'desc') THEN
        v_sort_ord := 'asc';
    END IF;

    -- Validate and normalize sort_column
    v_sort_col := lower(coalesce(sort_column, 'name'));
    IF v_sort_col NOT IN ('name', 'updated_at', 'created_at') THEN
        v_sort_col := 'name';
    END IF;

    -- Route to appropriate implementation
    IF v_sort_col = 'name' THEN
        -- Use list_objects_with_delimiter for name sorting (most efficient: O(k * log n))
        RETURN QUERY
        SELECT
            split_part(l.name, '/', levels) AS key,
            l.name AS name,
            l.id,
            l.updated_at,
            l.created_at,
            l.last_accessed_at,
            l.metadata
        FROM storage.list_objects_with_delimiter(
            bucket_name,
            coalesce(prefix, ''),
            '/',
            v_limit,
            start_after,
            '',
            v_sort_ord
        ) l;
    ELSE
        -- Use aggregation approach for timestamp sorting
        -- Not efficient for large datasets but supports correct pagination
        RETURN QUERY SELECT * FROM storage.search_by_timestamp(
            prefix, bucket_name, v_limit, levels, start_after,
            v_sort_ord, v_sort_col, sort_column_after
        );
    END IF;
END;
$$;


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
    parent_id uuid,
    CONSTRAINT "Comments_text_check" CHECK ((length(text) < 200))
);


--
-- Name: TABLE "Comments"; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public."Comments" IS 'Comments left by users about an image';


--
-- Name: COLUMN "Comments".parent_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public."Comments".parent_id IS 'The original comment this comment answers to';


--
-- Name: GroupInvites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."GroupInvites" (
    token text DEFAULT encode(extensions.gen_random_bytes(16), 'hex'::text) NOT NULL,
    group_id uuid NOT NULL,
    created_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    max_uses integer,
    uses integer DEFAULT 0 NOT NULL,
    revoked boolean DEFAULT false NOT NULL
);


--
-- Name: Groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Groups" (
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    name text DEFAULT 'My new group'::text NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    owner uuid,
    invite_permission text DEFAULT 'admin'::text NOT NULL,
    CONSTRAINT "Groups_invite_permission_check" CHECK ((invite_permission = ANY (ARRAY['owner'::text, 'admin'::text, 'everyone'::text]))),
    CONSTRAINT "Groups_name_check" CHECK ((length(name) < 20)),
    CONSTRAINT check_group_name_length CHECK (((length(name) > 2) AND (length(name) < 20)))
);


--
-- Name: ImageGroups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."ImageGroups" (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    image_id uuid NOT NULL,
    group_id uuid DEFAULT gen_random_uuid(),
    uploaded_at timestamp with time zone DEFAULT now()
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
    role text DEFAULT 'member'::text,
    CONSTRAINT "Members_role_check" CHECK ((role = ANY (ARRAY['owner'::text, 'admin'::text, 'member'::text, 'banned'::text])))
);


--
-- Name: NotifiedImageUsers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."NotifiedImageUsers" (
    image_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: Reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Reactions" (
    image_id uuid NOT NULL,
    user_id uuid NOT NULL,
    emoji text NOT NULL,
    CONSTRAINT "Reactions_emoji_check" CHECK ((char_length(emoji) <= 16))
);


--
-- Name: TABLE "Reactions"; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public."Reactions" IS 'Emoji reactions left by users on an image';


--
-- Name: Users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Users" (
    username text DEFAULT ''::text,
    id uuid NOT NULL,
    fcm_token text,
    notify_group_comments boolean DEFAULT false NOT NULL,
    notify_group_reactions boolean DEFAULT false NOT NULL,
    CONSTRAINT "Users_username_check" CHECK ((length(username) < 20))
);


--
-- Name: TABLE "Users"; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public."Users" IS 'contains usernames';


--
-- Name: COLUMN "Users".notify_group_comments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public."Users".notify_group_comments IS 'Users can choose whether they want to receive notifications about comment posted under other user''s images';


--
-- Name: COLUMN "Users".notify_group_reactions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public."Users".notify_group_reactions IS 'Users can choose whether they want to receive notifications about reactions posted on other user''s images';


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
    name text NOT NULL,
    type storage.buckettype DEFAULT 'ANALYTICS'::storage.buckettype NOT NULL,
    format text DEFAULT 'ICEBERG'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    deleted_at timestamp with time zone
);


--
-- Name: buckets_vectors; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.buckets_vectors (
    id text NOT NULL,
    type storage.buckettype DEFAULT 'VECTOR'::storage.buckettype NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: iceberg_namespaces; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.iceberg_namespaces (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    bucket_name text NOT NULL,
    name text NOT NULL COLLATE pg_catalog."C",
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    catalog_id uuid NOT NULL
);


--
-- Name: iceberg_tables; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.iceberg_tables (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    namespace_id uuid NOT NULL,
    bucket_name text NOT NULL,
    name text NOT NULL COLLATE pg_catalog."C",
    location text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    remote_table_id text,
    shard_key text,
    shard_id text,
    catalog_id uuid NOT NULL
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
    user_metadata jsonb
);


--
-- Name: COLUMN objects.owner; Type: COMMENT; Schema: storage; Owner: -
--

COMMENT ON COLUMN storage.objects.owner IS 'Field is deprecated, use owner_id instead';


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
    user_metadata jsonb,
    metadata jsonb
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
-- Name: vector_indexes; Type: TABLE; Schema: storage; Owner: -
--

CREATE TABLE storage.vector_indexes (
    id text DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL COLLATE pg_catalog."C",
    bucket_id text NOT NULL,
    data_type text NOT NULL,
    dimension integer NOT NULL,
    distance_metric text NOT NULL,
    metadata_configuration jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: Comments Comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Comments"
    ADD CONSTRAINT "Comments_pkey" PRIMARY KEY (id);


--
-- Name: GroupInvites GroupInvites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."GroupInvites"
    ADD CONSTRAINT "GroupInvites_pkey" PRIMARY KEY (token);


--
-- Name: Groups Groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Groups"
    ADD CONSTRAINT "Groups_pkey" PRIMARY KEY (id);


--
-- Name: ImageGroups ImageGroups_image_group_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."ImageGroups"
    ADD CONSTRAINT "ImageGroups_image_group_key" UNIQUE (image_id, group_id);


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
-- Name: Members Members_group_user_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Members"
    ADD CONSTRAINT "Members_group_user_unique" UNIQUE (group_id, user_id);


--
-- Name: Members Members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Members"
    ADD CONSTRAINT "Members_pkey" PRIMARY KEY (id);


--
-- Name: NotifiedImageUsers NotifiedImageUsers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NotifiedImageUsers"
    ADD CONSTRAINT "NotifiedImageUsers_pkey" PRIMARY KEY (image_id, user_id);


--
-- Name: Reactions Reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Reactions"
    ADD CONSTRAINT "Reactions_pkey" PRIMARY KEY (image_id, user_id, emoji);


--
-- Name: Users Users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Users"
    ADD CONSTRAINT "Users_pkey" PRIMARY KEY (id);


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
-- Name: buckets_vectors buckets_vectors_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.buckets_vectors
    ADD CONSTRAINT buckets_vectors_pkey PRIMARY KEY (id);


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
-- Name: vector_indexes vector_indexes_pkey; Type: CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.vector_indexes
    ADD CONSTRAINT vector_indexes_pkey PRIMARY KEY (id);


--
-- Name: GroupInvites_group_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "GroupInvites_group_id_idx" ON public."GroupInvites" USING btree (group_id);


--
-- Name: idx_comments_image_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_comments_image_group ON public."Comments" USING btree (image_id, group_id);


--
-- Name: idx_members_group_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_members_group_user ON public."Members" USING btree (group_id, user_id);


--
-- Name: bname; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX bname ON storage.buckets USING btree (name);


--
-- Name: bucketid_objname; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX bucketid_objname ON storage.objects USING btree (bucket_id, name);


--
-- Name: buckets_analytics_unique_name_idx; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX buckets_analytics_unique_name_idx ON storage.buckets_analytics USING btree (name) WHERE (deleted_at IS NULL);


--
-- Name: idx_iceberg_namespaces_bucket_id; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX idx_iceberg_namespaces_bucket_id ON storage.iceberg_namespaces USING btree (catalog_id, name);


--
-- Name: idx_iceberg_tables_location; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX idx_iceberg_tables_location ON storage.iceberg_tables USING btree (location);


--
-- Name: idx_iceberg_tables_namespace_id; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX idx_iceberg_tables_namespace_id ON storage.iceberg_tables USING btree (catalog_id, namespace_id, name);


--
-- Name: idx_multipart_uploads_list; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX idx_multipart_uploads_list ON storage.s3_multipart_uploads USING btree (bucket_id, key, created_at);


--
-- Name: idx_objects_bucket_id_name; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX idx_objects_bucket_id_name ON storage.objects USING btree (bucket_id, name COLLATE "C");


--
-- Name: idx_objects_bucket_id_name_lower; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX idx_objects_bucket_id_name_lower ON storage.objects USING btree (bucket_id, lower(name) COLLATE "C");


--
-- Name: name_prefix_search; Type: INDEX; Schema: storage; Owner: -
--

CREATE INDEX name_prefix_search ON storage.objects USING btree (name text_pattern_ops);


--
-- Name: vector_indexes_name_bucket_id_idx; Type: INDEX; Schema: storage; Owner: -
--

CREATE UNIQUE INDEX vector_indexes_name_bucket_id_idx ON storage.vector_indexes USING btree (name, bucket_id);


--
-- Name: Comments on-comment-insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER "on-comment-insert" AFTER INSERT ON public."Comments" FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('your_supabase_url/functions/v1/comment-notification', 'POST', '{"Content-type":"application/json","Authorization":"Bearer <SERVICE_ROLE_KEY>"}', '{}', '5000');


--
-- Name: ImageGroups on-image-delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER "on-image-delete" AFTER DELETE ON public."ImageGroups" FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('your_supabase_url/functions/v1/image-deleted-notification', 'POST', '{"Content-type":"application/json","Authorization":"Bearer <SERVICE_ROLE_KEY>"}', '{}', '5000');


--
-- Name: ImageGroups on-image-insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER "on-image-insert" AFTER INSERT ON public."ImageGroups" FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('your_supabase_url/functions/v1/image-notification', 'POST', '{"Content-type":"application/json","Authorization":"Bearer <SERVICE_ROLE_KEY>"}', '{}', '5000');


--
-- Name: Reactions on-reaction-insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER "on-reaction-insert" AFTER INSERT ON public."Reactions" FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('your_supabase_url/functions/v1/reaction-notification', 'POST', '{"Content-type":"application/json","Authorization":"Bearer <SERVICE_ROLE_KEY>"}', '{}', '5000');


--
-- Name: buckets enforce_bucket_name_length_trigger; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER enforce_bucket_name_length_trigger BEFORE INSERT OR UPDATE OF name ON storage.buckets FOR EACH ROW EXECUTE FUNCTION storage.enforce_bucket_name_length();


--
-- Name: objects on-image-insert-thumbnail; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER "on-image-insert-thumbnail" AFTER INSERT ON storage.objects FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('your_supabase_url/functions/v1/thumbnail-generation', 'POST', '{"Content-type":"application/json","Authorization":"Bearer <SERVICE_ROLE_KEY>"}', '{}', '5000');


--
-- Name: objects on_storage_object_delete; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER on_storage_object_delete AFTER DELETE ON storage.objects FOR EACH ROW EXECUTE FUNCTION public.handle_storage_delete();


--
-- Name: buckets protect_buckets_delete; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER protect_buckets_delete BEFORE DELETE ON storage.buckets FOR EACH STATEMENT EXECUTE FUNCTION storage.protect_delete();


--
-- Name: objects protect_objects_delete; Type: TRIGGER; Schema: storage; Owner: -
--

CREATE TRIGGER protect_objects_delete BEFORE DELETE ON storage.objects FOR EACH STATEMENT EXECUTE FUNCTION storage.protect_delete();


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
-- Name: Comments Comments_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Comments"
    ADD CONSTRAINT "Comments_parent_id_fkey" FOREIGN KEY (parent_id) REFERENCES public."Comments"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: Comments Comments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Comments"
    ADD CONSTRAINT "Comments_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public."Users"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: GroupInvites GroupInvites_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."GroupInvites"
    ADD CONSTRAINT "GroupInvites_created_by_fkey" FOREIGN KEY (created_by) REFERENCES public."Users"(id) ON DELETE CASCADE;


--
-- Name: GroupInvites GroupInvites_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."GroupInvites"
    ADD CONSTRAINT "GroupInvites_group_id_fkey" FOREIGN KEY (group_id) REFERENCES public."Groups"(id) ON DELETE CASCADE;


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
    ADD CONSTRAINT "Members_group_id_fkey" FOREIGN KEY (group_id) REFERENCES public."Groups"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: Members Members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Members"
    ADD CONSTRAINT "Members_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: NotifiedImageUsers NotifiedImageUsers_image_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NotifiedImageUsers"
    ADD CONSTRAINT "NotifiedImageUsers_image_id_fkey" FOREIGN KEY (image_id) REFERENCES public."Images"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: NotifiedImageUsers NotifiedImageUsers_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NotifiedImageUsers"
    ADD CONSTRAINT "NotifiedImageUsers_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public."Users"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: Reactions Reactions_image_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Reactions"
    ADD CONSTRAINT "Reactions_image_id_fkey" FOREIGN KEY (image_id) REFERENCES public."Images"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: Reactions Reactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Reactions"
    ADD CONSTRAINT "Reactions_user_id_fkey" FOREIGN KEY (user_id) REFERENCES public."Users"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: Users Users_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Users"
    ADD CONSTRAINT "Users_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: iceberg_namespaces iceberg_namespaces_catalog_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.iceberg_namespaces
    ADD CONSTRAINT iceberg_namespaces_catalog_id_fkey FOREIGN KEY (catalog_id) REFERENCES storage.buckets_analytics(id) ON DELETE CASCADE;


--
-- Name: iceberg_tables iceberg_tables_catalog_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.iceberg_tables
    ADD CONSTRAINT iceberg_tables_catalog_id_fkey FOREIGN KEY (catalog_id) REFERENCES storage.buckets_analytics(id) ON DELETE CASCADE;


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
-- Name: vector_indexes vector_indexes_bucket_id_fkey; Type: FK CONSTRAINT; Schema: storage; Owner: -
--

ALTER TABLE ONLY storage.vector_indexes
    ADD CONSTRAINT vector_indexes_bucket_id_fkey FOREIGN KEY (bucket_id) REFERENCES storage.buckets_vectors(id);


--
-- Name: Groups Admins can update the group name; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can update the group name" ON public."Groups" FOR UPDATE TO authenticated USING (public.is_admin_or_owner(id));


--
-- Name: Groups Allow owners to delete a group; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow owners to delete a group" ON public."Groups" FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public."Members"
  WHERE (("Members".group_id = "Groups".id) AND ("Members".user_id = ( SELECT auth.uid() AS uid)) AND ("Members".role = 'owner'::text)))));


--
-- Name: Groups Allow users to create groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow users to create groups" ON public."Groups" FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) IS NOT NULL));


--
-- Name: Comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."Comments" ENABLE ROW LEVEL SECURITY;

--
-- Name: Members Enable delete for users based on user_id; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable delete for users based on user_id" ON public."Members" FOR DELETE USING (((( SELECT auth.uid() AS uid) = user_id) AND (role <> 'banned'::text)));


--
-- Name: Users Enable insert for users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for users" ON public."Users" FOR INSERT TO authenticated WITH CHECK ((( SELECT auth.uid() AS uid) = id));


--
-- Name: Members Enable insert for users based on user_id; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Enable insert for users based on user_id" ON public."Members" FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: Groups Group members can see their groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Group members can see their groups" ON public."Groups" FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE ((m.group_id = "Groups".id) AND (m.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: Reactions Group members can select image reactions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Group members can select image reactions" ON public."Reactions" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ((public."ImageGroups" ig
     JOIN public."Members" mc ON ((mc.group_id = ig.group_id)))
     JOIN public."Members" mr ON ((mr.group_id = ig.group_id)))
  WHERE ((ig.image_id = "Reactions".image_id) AND (mc.user_id = ( SELECT auth.uid() AS uid)) AND (mc.role <> 'banned'::text) AND (mr.user_id = "Reactions".user_id) AND (mr.role <> 'banned'::text)))));


--
-- Name: ImageGroups Group members can select images from that group; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Group members can select images from that group" ON public."ImageGroups" FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE ((m.group_id = "ImageGroups".group_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.role <> 'banned'::text)))));


--
-- Name: Images Group members or owner can access images; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Group members or owner can access images" ON public."Images" FOR SELECT TO authenticated USING (((uploaded_by = ( SELECT auth.uid() AS uid)) OR (EXISTS ( SELECT 1
   FROM (public."ImageGroups" ig
     JOIN public."Members" m ON ((ig.group_id = m.group_id)))
  WHERE ((ig.image_id = "Images".id) AND (m.user_id = ( SELECT auth.uid() AS uid)))))));


--
-- Name: GroupInvites; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."GroupInvites" ENABLE ROW LEVEL SECURITY;

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
-- Name: Comments Members can insert comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Members can insert comments" ON public."Comments" FOR INSERT WITH CHECK (((user_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE ((m.group_id = "Comments".group_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.role <> 'banned'::text))))));


--
-- Name: Reactions Members can insert image reactions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Members can insert image reactions" ON public."Reactions" FOR INSERT WITH CHECK (((user_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM (public."ImageGroups" ig
     JOIN public."Members" m ON ((m.group_id = ig.group_id)))
  WHERE ((ig.image_id = "Reactions".image_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.role <> 'banned'::text))))));


--
-- Name: ImageGroups Members can insert images to groups; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Members can insert images to groups" ON public."ImageGroups" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE ((m.group_id = "ImageGroups".group_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.role <> 'banned'::text)))));


--
-- Name: NotifiedImageUsers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."NotifiedImageUsers" ENABLE ROW LEVEL SECURITY;

--
-- Name: Comments Only group members can select comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Only group members can select comments" ON public."Comments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM (public."ImageGroups" ig
     JOIN public."Members" m ON ((ig.group_id = m.group_id)))
  WHERE ((ig.image_id = "Comments".image_id) AND (m.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: Reactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."Reactions" ENABLE ROW LEVEL SECURITY;

--
-- Name: Users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public."Users" ENABLE ROW LEVEL SECURITY;

--
-- Name: Comments Users can delete their own comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete their own comments" ON public."Comments" FOR DELETE USING (((user_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM (public."ImageGroups" ig
     JOIN public."Members" m ON ((ig.group_id = m.group_id)))
  WHERE ((ig.image_id = "Comments".image_id) AND (m.user_id = ( SELECT auth.uid() AS uid)))))));


--
-- Name: Reactions Users can delete their own image reactions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can delete their own image reactions" ON public."Reactions" FOR DELETE USING ((user_id = ( SELECT auth.uid() AS uid)));


--
-- Name: Images Users can insert their own images; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can insert their own images" ON public."Images" FOR INSERT TO authenticated WITH CHECK ((uploaded_by = ( SELECT auth.uid() AS uid)));


--
-- Name: Users Users can see themselves and fellow group members; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can see themselves and fellow group members" ON public."Users" FOR SELECT TO authenticated USING (((( SELECT auth.uid() AS uid) = id) OR (EXISTS ( SELECT 1
   FROM (public."Members" m1
     JOIN public."Members" m2 ON ((m1.group_id = m2.group_id)))
  WHERE ((m1.user_id = ( SELECT auth.uid() AS uid)) AND (m2.user_id = "Users".id))))));


--
-- Name: Comments Users can update their own comments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own comments" ON public."Comments" FOR UPDATE USING (((user_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM (public."ImageGroups" ig
     JOIN public."Members" m ON ((ig.group_id = m.group_id)))
  WHERE ((ig.image_id = "Comments".image_id) AND (m.user_id = ( SELECT auth.uid() AS uid)))))));


--
-- Name: Users Users can update their own row; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can update their own row" ON public."Users" FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = id)) WITH CHECK ((( SELECT auth.uid() AS uid) = id));


--
-- Name: Members allow_admins_owners_update_roles; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY allow_admins_owners_update_roles ON public."Members" FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE ((m.group_id = "Members".group_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.role = ANY (ARRAY['owner'::text, 'admin'::text]))))));


--
-- Name: Members members_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY members_read ON public."Members" FOR SELECT USING (((role <> 'banned'::text) OR public.is_admin_or_owner(group_id)));


--
-- Name: objects Give users authenticated access to insert; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Give users authenticated access to insert" ON storage.objects FOR INSERT TO authenticated WITH CHECK (((auth.uid() IS NOT NULL) AND (bucket_id = 'images'::text)));


--
-- Name: objects Group admins can update the group icon 1tf5vm4_0; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Group admins can update the group icon 1tf5vm4_0" ON storage.objects FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'group-icons'::text) AND public.is_admin_or_owner((name)::uuid)));


--
-- Name: objects Group admins can update the group icon 1tf5vm4_1; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Group admins can update the group icon 1tf5vm4_1" ON storage.objects FOR UPDATE TO authenticated USING (((bucket_id = 'group-icons'::text) AND public.is_admin_or_owner((name)::uuid)));


--
-- Name: objects Group admins can update the group icon 1tf5vm4_2; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Group admins can update the group icon 1tf5vm4_2" ON storage.objects FOR DELETE TO authenticated USING (((bucket_id = 'group-icons'::text) AND public.is_admin_or_owner((name)::uuid)));


--
-- Name: objects Group members can access the group icon 1tf5vm4_0; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Group members can access the group icon 1tf5vm4_0" ON storage.objects FOR SELECT TO authenticated USING (((bucket_id = 'group-icons'::text) AND (EXISTS ( SELECT 1
   FROM public."Members" m
  WHERE (((m.group_id)::text = objects.name) AND (m.user_id = auth.uid()))))));


--
-- Name: objects Group members can see image thumbnails; Type: POLICY; Schema: storage; Owner: -
--

CREATE POLICY "Group members can see image thumbnails" ON storage.objects FOR SELECT TO authenticated USING (((bucket_id = 'image-thumbnails'::text) AND (EXISTS ( WITH user_groups AS (
         SELECT "Members".group_id
           FROM public."Members"
          WHERE ("Members".user_id = auth.uid())
        )
 SELECT 1
   FROM (public."ImageGroups" ig
     JOIN user_groups ug ON ((ig.group_id = ug.group_id)))
  WHERE (ig.image_id = (objects.name)::uuid)))));


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
-- Name: buckets_vectors; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.buckets_vectors ENABLE ROW LEVEL SECURITY;

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
-- Name: s3_multipart_uploads; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.s3_multipart_uploads ENABLE ROW LEVEL SECURITY;

--
-- Name: s3_multipart_uploads_parts; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.s3_multipart_uploads_parts ENABLE ROW LEVEL SECURITY;

--
-- Name: vector_indexes; Type: ROW SECURITY; Schema: storage; Owner: -
--

ALTER TABLE storage.vector_indexes ENABLE ROW LEVEL SECURITY;

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

GRANT USAGE ON SCHEMA storage TO postgres WITH GRANT OPTION;
GRANT USAGE ON SCHEMA storage TO anon;
GRANT USAGE ON SCHEMA storage TO authenticated;
GRANT USAGE ON SCHEMA storage TO service_role;
GRANT ALL ON SCHEMA storage TO supabase_storage_admin WITH GRANT OPTION;
GRANT ALL ON SCHEMA storage TO dashboard_user;
SET SESSION AUTHORIZATION postgres;
GRANT USAGE ON SCHEMA storage TO postgres;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION postgres;
GRANT USAGE ON SCHEMA storage TO authenticated;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION postgres;
GRANT USAGE ON SCHEMA storage TO service_role;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION postgres;
GRANT USAGE ON SCHEMA storage TO supabase_storage_admin;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION postgres;
GRANT USAGE ON SCHEMA storage TO dashboard_user;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION postgres;
GRANT USAGE ON SCHEMA storage TO anon;
RESET SESSION AUTHORIZATION;


--
-- Name: FUNCTION add_comment(image_id uuid, group_id uuid, text text, parent_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.add_comment(image_id uuid, group_id uuid, text text, parent_id uuid) TO anon;
GRANT ALL ON FUNCTION public.add_comment(image_id uuid, group_id uuid, text text, parent_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.add_comment(image_id uuid, group_id uuid, text text, parent_id uuid) TO service_role;


--
-- Name: FUNCTION add_image_to_groups(p_image_id uuid, p_group_ids uuid[]); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.add_image_to_groups(p_image_id uuid, p_group_ids uuid[]) TO anon;
GRANT ALL ON FUNCTION public.add_image_to_groups(p_image_id uuid, p_group_ids uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.add_image_to_groups(p_image_id uuid, p_group_ids uuid[]) TO service_role;


--
-- Name: FUNCTION ban_user(group_id uuid, target_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.ban_user(group_id uuid, target_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.ban_user(group_id uuid, target_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.ban_user(group_id uuid, target_user_id uuid) TO service_role;


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
-- Name: FUNCTION create_group_invite(p_group_id uuid, p_expires_at timestamp with time zone, p_max_uses integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_group_invite(p_group_id uuid, p_expires_at timestamp with time zone, p_max_uses integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_group_invite(p_group_id uuid, p_expires_at timestamp with time zone, p_max_uses integer) TO anon;
GRANT ALL ON FUNCTION public.create_group_invite(p_group_id uuid, p_expires_at timestamp with time zone, p_max_uses integer) TO authenticated;
GRANT ALL ON FUNCTION public.create_group_invite(p_group_id uuid, p_expires_at timestamp with time zone, p_max_uses integer) TO service_role;


--
-- Name: FUNCTION create_user_profile(username text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_user_profile(username text) TO anon;
GRANT ALL ON FUNCTION public.create_user_profile(username text) TO authenticated;
GRANT ALL ON FUNCTION public.create_user_profile(username text) TO service_role;


--
-- Name: FUNCTION delete_account(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_account() FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_account() TO authenticated;
GRANT ALL ON FUNCTION public.delete_account() TO service_role;


--
-- Name: FUNCTION delete_comment(comment_id uuid, image_id uuid, group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.delete_comment(comment_id uuid, image_id uuid, group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.delete_comment(comment_id uuid, image_id uuid, group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_comment(comment_id uuid, image_id uuid, group_id uuid) TO service_role;


--
-- Name: FUNCTION delete_image(image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.delete_image(image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.delete_image(image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.delete_image(image_id uuid) TO service_role;


--
-- Name: FUNCTION edit_username(new_username text); Type: ACL; Schema: public; Owner: -
--

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
-- Name: FUNCTION get_comment_notification(p_comment_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_comment_notification(p_comment_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_comment_notification(p_comment_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_comment_notification(p_comment_id uuid) TO service_role;


--
-- Name: FUNCTION get_comments(image_id uuid, group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_comments(image_id uuid, group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_comments(image_id uuid, group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_comments(image_id uuid, group_id uuid) TO service_role;


--
-- Name: FUNCTION get_group_details(group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_group_details(group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_group_details(group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_group_details(group_id uuid) TO service_role;



--
-- Name: FUNCTION get_group_images(p_group_id uuid, p_limit integer, p_before_created_at timestamp with time zone, p_before_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_group_images(p_group_id uuid, p_limit integer, p_before_created_at timestamp with time zone, p_before_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_group_images(p_group_id uuid, p_limit integer, p_before_created_at timestamp with time zone, p_before_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_group_images(p_group_id uuid, p_limit integer, p_before_created_at timestamp with time zone, p_before_id uuid) TO service_role;


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
-- Name: FUNCTION get_image_comment_count(p_image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_image_comment_count(p_image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_image_comment_count(p_image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_image_comment_count(p_image_id uuid) TO service_role;


--
-- Name: FUNCTION get_image_comments_grouped(p_image_id uuid, p_primary_group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_image_comments_grouped(p_image_id uuid, p_primary_group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_image_comments_grouped(p_image_id uuid, p_primary_group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_image_comments_grouped(p_image_id uuid, p_primary_group_id uuid) TO service_role;


--
-- Name: FUNCTION get_image_details(image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_image_details(image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_image_details(image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_image_details(image_id uuid) TO service_role;


--
-- Name: FUNCTION get_image_groups(p_image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_image_groups(p_image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_image_groups(p_image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_image_groups(p_image_id uuid) TO service_role;


--
-- Name: FUNCTION get_image_notification(p_image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_image_notification(p_image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_image_notification(p_image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_image_notification(p_image_id uuid) TO service_role;


--
-- Name: FUNCTION get_image_reactions(p_image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_image_reactions(p_image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_image_reactions(p_image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_image_reactions(p_image_id uuid) TO service_role;


--
-- Name: FUNCTION get_image_reactors(p_image_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_image_reactors(p_image_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_image_reactors(p_image_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_image_reactors(p_image_id uuid) TO service_role;


--
-- Name: FUNCTION get_latest_images(p_count integer, p_group_ids text[], p_before_created_at timestamp with time zone, p_before_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_latest_images(p_count integer, p_group_ids text[], p_before_created_at timestamp with time zone, p_before_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_latest_images(p_count integer, p_group_ids text[], p_before_created_at timestamp with time zone, p_before_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_latest_images(p_count integer, p_group_ids text[], p_before_created_at timestamp with time zone, p_before_id uuid) TO service_role;


--
-- Name: FUNCTION get_notify_group_comments(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_notify_group_comments() TO anon;
GRANT ALL ON FUNCTION public.get_notify_group_comments() TO authenticated;
GRANT ALL ON FUNCTION public.get_notify_group_comments() TO service_role;


--
-- Name: FUNCTION get_notify_group_reactions(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_notify_group_reactions() TO anon;
GRANT ALL ON FUNCTION public.get_notify_group_reactions() TO authenticated;
GRANT ALL ON FUNCTION public.get_notify_group_reactions() TO service_role;


--
-- Name: FUNCTION get_reaction_notification(p_image_id uuid, p_reactor_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_reaction_notification(p_image_id uuid, p_reactor_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_reaction_notification(p_image_id uuid, p_reactor_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_reaction_notification(p_image_id uuid, p_reactor_id uuid) TO service_role;


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
-- Name: FUNCTION handle_new_user(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.handle_new_user() TO anon;
GRANT ALL ON FUNCTION public.handle_new_user() TO authenticated;
GRANT ALL ON FUNCTION public.handle_new_user() TO service_role;


--
-- Name: FUNCTION handle_storage_delete(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.handle_storage_delete() TO anon;
GRANT ALL ON FUNCTION public.handle_storage_delete() TO authenticated;
GRANT ALL ON FUNCTION public.handle_storage_delete() TO service_role;


--
-- Name: FUNCTION is_admin_or_owner(p_group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_admin_or_owner(p_group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.is_admin_or_owner(p_group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.is_admin_or_owner(p_group_id uuid) TO service_role;


--
-- Name: FUNCTION join_group_by_invite(p_token text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.join_group_by_invite(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.join_group_by_invite(p_token text) TO anon;
GRANT ALL ON FUNCTION public.join_group_by_invite(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.join_group_by_invite(p_token text) TO service_role;


--
-- Name: FUNCTION leave_group(group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.leave_group(group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.leave_group(group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.leave_group(group_id uuid) TO service_role;


--
-- Name: FUNCTION list_group_invites(p_group_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_group_invites(p_group_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_group_invites(p_group_id uuid) TO anon;
GRANT ALL ON FUNCTION public.list_group_invites(p_group_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.list_group_invites(p_group_id uuid) TO service_role;


--
-- Name: FUNCTION manage_member_role(group_id uuid, target_user_id uuid, action text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.manage_member_role(group_id uuid, target_user_id uuid, action text) TO anon;
GRANT ALL ON FUNCTION public.manage_member_role(group_id uuid, target_user_id uuid, action text) TO authenticated;
GRANT ALL ON FUNCTION public.manage_member_role(group_id uuid, target_user_id uuid, action text) TO service_role;


--
-- Name: FUNCTION register_fcm_token(p_fcm_token text, p_username text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.register_fcm_token(p_fcm_token text, p_username text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.register_fcm_token(p_fcm_token text, p_username text) TO anon;
GRANT ALL ON FUNCTION public.register_fcm_token(p_fcm_token text, p_username text) TO authenticated;
GRANT ALL ON FUNCTION public.register_fcm_token(p_fcm_token text, p_username text) TO service_role;


--
-- Name: FUNCTION register_uploaded_image(image_id uuid, group_ids text[], image_description text); Type: ACL; Schema: public; Owner: -
--

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
-- Name: FUNCTION remove_image_from_groups(p_image_id uuid, p_group_ids uuid[]); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.remove_image_from_groups(p_image_id uuid, p_group_ids uuid[]) TO anon;
GRANT ALL ON FUNCTION public.remove_image_from_groups(p_image_id uuid, p_group_ids uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.remove_image_from_groups(p_image_id uuid, p_group_ids uuid[]) TO service_role;


--
-- Name: FUNCTION request_image_uuid(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.request_image_uuid() TO anon;
GRANT ALL ON FUNCTION public.request_image_uuid() TO authenticated;
GRANT ALL ON FUNCTION public.request_image_uuid() TO service_role;


--
-- Name: FUNCTION revoke_group_invite(p_token text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.revoke_group_invite(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.revoke_group_invite(p_token text) TO anon;
GRANT ALL ON FUNCTION public.revoke_group_invite(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.revoke_group_invite(p_token text) TO service_role;


--
-- Name: FUNCTION set_group_invite_permission(p_group_id uuid, p_permission text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_group_invite_permission(p_group_id uuid, p_permission text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_group_invite_permission(p_group_id uuid, p_permission text) TO anon;
GRANT ALL ON FUNCTION public.set_group_invite_permission(p_group_id uuid, p_permission text) TO authenticated;
GRANT ALL ON FUNCTION public.set_group_invite_permission(p_group_id uuid, p_permission text) TO service_role;


--
-- Name: FUNCTION set_notify_group_comments(enabled boolean); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_notify_group_comments(enabled boolean) TO anon;
GRANT ALL ON FUNCTION public.set_notify_group_comments(enabled boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_notify_group_comments(enabled boolean) TO service_role;


--
-- Name: FUNCTION set_notify_group_reactions(enabled boolean); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_notify_group_reactions(enabled boolean) TO anon;
GRANT ALL ON FUNCTION public.set_notify_group_reactions(enabled boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_notify_group_reactions(enabled boolean) TO service_role;


--
-- Name: FUNCTION toggle_reaction(p_image_id uuid, p_emoji text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.toggle_reaction(p_image_id uuid, p_emoji text) TO anon;
GRANT ALL ON FUNCTION public.toggle_reaction(p_image_id uuid, p_emoji text) TO authenticated;
GRANT ALL ON FUNCTION public.toggle_reaction(p_image_id uuid, p_emoji text) TO service_role;


--
-- Name: FUNCTION unban_user(group_id uuid, target_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.unban_user(group_id uuid, target_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.unban_user(group_id uuid, target_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.unban_user(group_id uuid, target_user_id uuid) TO service_role;


--
-- Name: FUNCTION update_comment(comment_id uuid, image_id uuid, group_id uuid, text text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_comment(comment_id uuid, image_id uuid, group_id uuid, text text) TO anon;
GRANT ALL ON FUNCTION public.update_comment(comment_id uuid, image_id uuid, group_id uuid, text text) TO authenticated;
GRANT ALL ON FUNCTION public.update_comment(comment_id uuid, image_id uuid, group_id uuid, text text) TO service_role;


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
-- Name: TABLE "GroupInvites"; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public."GroupInvites" TO anon;
GRANT ALL ON TABLE public."GroupInvites" TO authenticated;
GRANT ALL ON TABLE public."GroupInvites" TO service_role;


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
-- Name: TABLE "NotifiedImageUsers"; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public."NotifiedImageUsers" TO anon;
GRANT ALL ON TABLE public."NotifiedImageUsers" TO authenticated;
GRANT ALL ON TABLE public."NotifiedImageUsers" TO service_role;


--
-- Name: TABLE "Reactions"; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public."Reactions" TO anon;
GRANT ALL ON TABLE public."Reactions" TO authenticated;
GRANT ALL ON TABLE public."Reactions" TO service_role;


--
-- Name: TABLE "Users"; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public."Users" TO anon;
GRANT ALL ON TABLE public."Users" TO authenticated;
GRANT ALL ON TABLE public."Users" TO service_role;


--
-- Name: TABLE buckets; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.buckets TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE storage.buckets TO service_role;
GRANT ALL ON TABLE storage.buckets TO authenticated;
GRANT ALL ON TABLE storage.buckets TO anon;
SET SESSION AUTHORIZATION postgres;
GRANT ALL ON TABLE storage.buckets TO authenticated;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION postgres;
GRANT ALL ON TABLE storage.buckets TO service_role;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION postgres;
GRANT ALL ON TABLE storage.buckets TO anon;
RESET SESSION AUTHORIZATION;


--
-- Name: TABLE buckets_analytics; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.buckets_analytics TO service_role;
GRANT ALL ON TABLE storage.buckets_analytics TO authenticated;
GRANT ALL ON TABLE storage.buckets_analytics TO anon;


--
-- Name: TABLE buckets_vectors; Type: ACL; Schema: storage; Owner: -
--

GRANT SELECT ON TABLE storage.buckets_vectors TO service_role;
GRANT SELECT ON TABLE storage.buckets_vectors TO authenticated;
GRANT SELECT ON TABLE storage.buckets_vectors TO anon;


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
-- Name: TABLE objects; Type: ACL; Schema: storage; Owner: -
--

GRANT ALL ON TABLE storage.objects TO postgres WITH GRANT OPTION;
GRANT ALL ON TABLE storage.objects TO service_role;
GRANT ALL ON TABLE storage.objects TO authenticated;
GRANT ALL ON TABLE storage.objects TO anon;
SET SESSION AUTHORIZATION postgres;
GRANT ALL ON TABLE storage.objects TO authenticated;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION postgres;
GRANT ALL ON TABLE storage.objects TO service_role;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION postgres;
GRANT ALL ON TABLE storage.objects TO anon;
RESET SESSION AUTHORIZATION;


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
-- Name: TABLE vector_indexes; Type: ACL; Schema: storage; Owner: -
--

GRANT SELECT ON TABLE storage.vector_indexes TO service_role;
GRANT SELECT ON TABLE storage.vector_indexes TO authenticated;
GRANT SELECT ON TABLE storage.vector_indexes TO anon;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: storage; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: storage; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: storage; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA storage GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--

