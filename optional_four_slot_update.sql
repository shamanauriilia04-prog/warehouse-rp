-- Run only if you want the database itself to enforce four open slots. Does not delete data.
-- First ensure no soldier currently has five active slots on a single day.
create or replace function public.perform_action(p_action text,p_item uuid default null,p_soldier uuid default null,p_issue uuid default null,p_qty integer default null,p_name text default null,p_day date default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_actor text; v_item public.items%rowtype; v_issue public.issues%rowtype; v_available integer; v_now_day date := timezone('Europe/Paris',now())::date; v_count integer;
begin
 v_actor:=public.my_name();
 if v_actor is null then raise exception 'Unauthorized'; end if;
 if p_action='add_soldier' then
   if length(trim(coalesce(p_name,'')))<2 then raise exception 'Invalid name'; end if;
   insert into public.soldiers(name) values(trim(p_name));
 elsif p_action='retire_soldier' then
   update public.soldiers set active=false,retired_at=now() where id=p_soldier and active=true;
 elsif p_action='restore_soldier' then
   update public.soldiers set active=true,retired_at=null where id=p_soldier;
 elsif p_action='add_item' then
   if length(trim(coalesce(p_name,'')))<2 then raise exception 'Invalid name'; end if;
   insert into public.items(name) values(trim(p_name));
 elsif p_action='stock' then
   if p_qty is null or p_qty<=0 or p_qty>100000 then raise exception 'Invalid quantity'; end if;
   select * into v_item from public.items where id=p_item for update;
   if not found then raise exception 'Item not found'; end if;
   update public.items set added_qty=added_qty+p_qty where id=p_item;
   insert into public.stock_events(item_id,qty,actor) values(p_item,p_qty,v_actor);
 elsif p_action='issue' then
   if p_day is distinct from v_now_day then raise exception 'Only current-day issuance is allowed'; end if;
   if not exists(select 1 from public.soldiers where id=p_soldier and active=true) then raise exception 'Soldier not active'; end if;
   select * into v_item from public.items where id=p_item for update;
   if not found then raise exception 'Item not found'; end if;
   select count(*) into v_count from public.issues where soldier_id=p_soldier and issue_day=v_now_day and status='out';
   if v_count>=4 then raise exception 'Four active slots maximum'; end if;
   select v_item.initial_qty+v_item.added_qty-count(*) into v_available from public.issues where item_id=p_item and status in ('out','lost');
   if v_available<=0 then raise exception 'No stock available'; end if;
   insert into public.issues(soldier_id,item_id,issued_by,issue_day) values(p_soldier,p_item,v_actor,v_now_day);
 elsif p_action in ('returned','lost') then
   select * into v_issue from public.issues where id=p_issue for update;
   if not found or v_issue.status<>'out' then raise exception 'Issue already resolved'; end if;
   perform 1 from public.items where id=v_issue.item_id for update;
   update public.issues set status=p_action,resolved_at=now(),resolved_day=v_now_day,resolved_by=v_actor,resolved_by_uid=auth.uid() where id=p_issue;
 elsif p_action in ('all_returned','all_lost') then
   if p_day is null or p_day>v_now_day then raise exception 'Invalid date'; end if;
   -- Lock item rows consistently before bulk change.
   perform 1 from public.items where id in (select item_id from public.issues where soldier_id=p_soldier and issue_day=p_day and status='out') order by id for update;
   update public.issues set status=case when p_action='all_returned' then 'returned' else 'lost' end,resolved_at=now(),resolved_day=v_now_day,resolved_by=v_actor,resolved_by_uid=auth.uid() where soldier_id=p_soldier and issue_day=p_day and status='out';
 else raise exception 'Unknown action'; end if;
 return jsonb_build_object('ok',true);
end $$;
