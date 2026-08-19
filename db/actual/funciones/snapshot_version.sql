CREATE OR REPLACE FUNCTION public.snapshot_version()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT 1 $function$
