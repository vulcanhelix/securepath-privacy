-- ACCEPTANCE TEST — activate a Cyber Essentials content pack against the SAME screens.
-- This migration is ALL content (one content_pack + rows in the five content tables). If the
-- screens then render it with no code change, the content-driven architecture holds. Adding a
-- framework touches zero schema — that is the acceptance test, in the DB.
-- (cyber_essentials already exists in the frameworks registry, track_kind='cyber', from the spine.)

BEGIN;

-- global content pack for the framework
INSERT INTO public.content_packs (practice_id, framework_key, version, label, status)
  VALUES (NULL, 'cyber_essentials', 1, 'Cyber Essentials v3.2 (SA)', 'published');

-- ---------- Stage 1: assessment questions (5 controls) ----------
INSERT INTO public.assessment_questions
  (framework, content_pack_id, section_id, section_name, question_number, question, why_matters, regulatory_ref, risk, evidence_req, remediation, uid)
SELECT 'cyber_essentials', cp.id, x.section_id, x.section_name, x.qn, x.question, x.why, x.ref, x.risk, x.evidence, x.remediation, 'ce.'||x.uid
FROM (SELECT id FROM content_packs WHERE framework_key='cyber_essentials' AND version=1 AND practice_id IS NULL) cp,
(VALUES
  (1,'Firewalls',1,'Are boundary firewalls or internet gateways in place at every internet connection?','Boundary firewalls are the first line of defence against internet-based attacks.','CE Control 1','Critical','Firewall inventory / boundary diagram','Deploy a firewall at every internet boundary.','fw1'),
  (1,'Firewalls',2,'Have default firewall administrative passwords been changed and remote admin disabled?','Default credentials and open remote admin are trivially exploited.','CE Control 1','Critical','Firewall configuration record','Change defaults; disable internet-facing admin.','fw2'),
  (2,'Secure Configuration',1,'Are unnecessary user accounts, software and services removed or disabled?','Reducing the attack surface removes easy footholds.','CE Control 2','High','Build / hardening standard','Remove unused accounts, software and services.','sc1'),
  (2,'Secure Configuration',2,'Are devices hardened to a documented secure configuration standard?','A documented baseline makes secure builds repeatable.','CE Control 2','High','Secure configuration standard','Document and apply a hardening standard.','sc2'),
  (3,'Security Update Management',1,'Are all operating systems and applications supported and licensed?','Unsupported software receives no security fixes.','CE Control 3','High','Asset & software inventory','Remove or replace unsupported software.','up1'),
  (3,'Security Update Management',2,'Are security updates applied within 14 days of release?','Timely patching closes known vulnerabilities before exploitation.','CE Control 3','Critical','Patch status report','Establish a 14-day patch cycle.','up2'),
  (4,'User Access Control',1,'Is there an approved process to create, review and remove user accounts?','Uncontrolled accounts lead to unauthorised access.','CE Control 4','High','Access control matrix','Implement account provisioning/de-provisioning with approval.','ac1'),
  (4,'User Access Control',2,'Is multi-factor authentication enabled on cloud services and admin accounts?','MFA blocks the majority of credential-based attacks.','CE Control 4','Critical','MFA configuration evidence','Enable MFA on cloud and privileged accounts.','ac2'),
  (5,'Malware Protection',1,'Is anti-malware deployed and kept up to date on all devices?','Malware protection detects and blocks common threats.','CE Control 5','High','Anti-malware / EDR status report','Deploy and auto-update anti-malware on all devices.','mw1'),
  (5,'Malware Protection',2,'Where used, is application allow-listing restricting execution to approved software?','Allow-listing prevents unapproved and malicious code running.','CE Control 5','Medium','Allow-listing configuration','Restrict execution to approved applications.','mw2')
) AS x(section_id,section_name,qn,question,why,ref,risk,evidence,remediation,uid);

-- ---------- Stage 2: document checklist ----------
INSERT INTO public.document_checklists (framework_key, content_pack_id, slot_key, name, category, required, sort, description)
SELECT 'cyber_essentials', cp.id, x.slot_key, x.name, x.category, x.required, x.sort, x.description
FROM (SELECT id FROM content_packs WHERE framework_key='cyber_essentials' AND version=1 AND practice_id IS NULL) cp,
(VALUES
  ('boundary_diagram','Network / boundary diagram','register',true,10,'Internet boundaries and firewalls.'),
  ('firewall_config','Firewall configuration record','register',true,20,'Firewall rules, changed defaults, disabled remote admin.'),
  ('secure_config_standard','Secure configuration standard','policy',true,30,'Documented device hardening baseline.'),
  ('asset_inventory','Asset & software inventory','register',true,40,'Supported/licensed hardware and software.'),
  ('patch_report','Patch / update status report','register',true,50,'Evidence updates applied within 14 days.'),
  ('access_matrix_ce','User access control matrix & MFA config','register',true,60,'Accounts, privileges and MFA coverage.'),
  ('antimalware_report','Anti-malware / EDR status report','register',true,70,'Deployment and update status per device.'),
  ('ce_submission','Cyber Essentials self-assessment submission','governance',true,80,'The completed CE self-assessment pack.')
) AS x(slot_key,name,category,required,sort,description);

-- ---------- Stage 3: policy templates ----------
INSERT INTO public.policy_templates (framework_key, content_pack_id, slot_key, name, body)
SELECT 'cyber_essentials', cp.id, x.slot_key, x.name, x.body
FROM (SELECT id FROM content_packs WHERE framework_key='cyber_essentials' AND version=1 AND practice_id IS NULL) cp,
(VALUES
  ('secure_config_standard','Secure Configuration Standard', E'# Secure Configuration Standard\n\n## Scope\nAll servers, workstations and mobile devices.\n\n## Baseline\n- Remove/disable unnecessary accounts, software and services.\n- Change all default credentials.\n- Disable auto-run/auto-play.\n- Enforce device lock and disk encryption.\n\n_Owner: IT · Review annually._'),
  ('patch_policy_ce','Patch Management Policy', E'# Patch Management Policy\n\nSecurity updates for operating systems and applications are applied within **14 days** of release.\n\n## Process\n1. Identify supported/licensed software (asset inventory).\n2. Apply critical/security updates within 14 days.\n3. Remove unsupported software.\n4. Record patch status.\n\n_Owner: IT · Review annually._')
) AS x(slot_key,name,body);

-- ---------- Stage 4: manual outline (CE submission pack) ----------
INSERT INTO public.manual_outlines (framework_key, content_pack_id, chapter_key, title, clause_ref, sort, source_slots, narrative)
SELECT 'cyber_essentials', cp.id, x.chapter_key, x.title, x.clause_ref, x.sort, x.source_slots::text[], x.narrative
FROM (SELECT id FROM content_packs WHERE framework_key='cyber_essentials' AND version=1 AND practice_id IS NULL) cp,
(VALUES
  ('intro','Introduction & Scope','CE', 10, '{ce_submission}', 'Scope of the Cyber Essentials assessment.'),
  ('firewalls','Firewalls','CE Control 1', 20, '{boundary_diagram,firewall_config}', 'Boundary firewalls at every internet connection.'),
  ('secure_config','Secure Configuration','CE Control 2', 30, '{secure_config_standard,asset_inventory}', 'Devices hardened to a documented standard.'),
  ('updates','Security Update Management','CE Control 3', 40, '{patch_report,asset_inventory}', 'Supported software, patched within 14 days.'),
  ('access_control','User Access Control','CE Control 4', 50, '{access_matrix_ce}', 'Controlled accounts and MFA.'),
  ('malware','Malware Protection','CE Control 5', 60, '{antimalware_report}', 'Anti-malware and allow-listing.')
) AS x(chapter_key,title,clause_ref,sort,source_slots,narrative);

-- ---------- Stage 5: task library ----------
INSERT INTO public.task_templates (framework_key, content_pack_id, theme, title, responsible, timeframe, output, priority, sort)
SELECT 'cyber_essentials', cp.id, x.theme, x.title, x.responsible, x.timeframe, x.output, x.priority, x.sort
FROM (SELECT id FROM content_packs WHERE framework_key='cyber_essentials' AND version=1 AND practice_id IS NULL) cp,
(VALUES
  ('firewalls','Deploy boundary firewalls at every internet connection','IT','Week 1','Firewall inventory','critical',10),
  ('firewalls','Change default firewall credentials & disable remote admin','IT','Week 1','Firewall config record','critical',20),
  ('secure_config','Document & apply the secure configuration standard','IT','Weeks 1–3','Secure config standard','high',30),
  ('secure_config','Remove unnecessary accounts, software and services','IT','Weeks 1–2','Hardening checklist','medium',40),
  ('updates','Establish 14-day security patching','IT','Weeks 1–2','Patch status report','critical',50),
  ('updates','Remove unsupported / unlicensed software','IT','Weeks 2–4','Asset inventory','high',60),
  ('access_control','Enforce MFA on cloud services & admin accounts','IT','Weeks 1–2','MFA config evidence','critical',70),
  ('malware','Deploy and auto-update anti-malware / EDR','IT','Weeks 1–2','Anti-malware status report','high',80)
) AS x(theme,title,responsible,timeframe,output,priority,sort);

COMMIT;
