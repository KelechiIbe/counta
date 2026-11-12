-- The owner's manage-settings flag is off so only the owner comparison makes it true.
-- setup
update members set p_manage_settings = false where id = tests.id('m_owner');
-- call
select private.mfa_required(auth.uid())
