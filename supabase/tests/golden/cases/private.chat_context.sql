-- The owner's own permission flags are off: the owner's permissions come from the role.
-- setup
update members set p_manage_team = false, p_file_tax = false where id = tests.id('m_owner');
insert into chat_links (user_id, org_id, channel, status, phone) select m.user_id, m.org_id, 'whatsapp', 'active', '23480300000' || row_number() over (order by m.email) from members m where m.org_id = tests.id('org') and m.user_id is not null;
-- call
select private.chat_context(l) from chat_links l where l.org_id = tests.id('org') and l.user_id = auth.uid()
