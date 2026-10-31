-- Scheduled jobs of Classi (pg_cron). A restore of schema.sql + data.sql does not bring them back (the cron
-- schema is managed by Supabase): run this once after restoring into a new project. Safe to run again.
do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname in ('classi-reminders', 'classi-push', 'classi-report-reminders', 'classi-subscriptions', 'classi-review-prompts', 'classi-group-sessions', 'classi-today');
  perform cron.schedule('classi-reminders', '*/5 * * * *', 'select public.send_reminders()');
  perform cron.schedule('classi-push', '* * * * *', 'select public.push_kick()');
  perform cron.schedule('classi-report-reminders', '*/10 * * * *', 'select public.report_reminders()');
  perform cron.schedule('classi-subscriptions', '7 9 * * *', 'select public.subscription_reminders()');
  perform cron.schedule('classi-review-prompts', '*/30 * * * *', 'select public.review_prompts()');
  perform cron.schedule('classi-group-sessions', '17 3 * * *', 'select public.extend_group_sessions()');
  perform cron.schedule('classi-today', '*/5 * * * *', 'select public.send_today_reminders()');
end $$;
select jobname, schedule from cron.job where jobname like 'classi-%' order by 1;
