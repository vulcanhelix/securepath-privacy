-- Replace the placeholder POPIA checklist with the authoritative expected-document
-- inventory extracted from SecurePath's own 6-phase POPIA framework
-- (docs/extracted/Implementation App/PrivacyFramework.html, the PHASES array —
-- each task's `output` is a document/register the client should hold on file).
-- Privacy-track documents only. The 9 cyber-track policies in Phase 3.2 (AUP, Password,
-- BYOD, Backup, Patch, Clean Desk, Third-Party Security, IR Policy, Info Security) belong
-- to the cyber content pack (iso27701 / cyber_essentials), not the POPIA checklist.
-- Still content — William can refine any row; this is one migration, no code change.

BEGIN;

-- clear the placeholder set (safe: no production documents are linked yet)
DELETE FROM public.document_checklists WHERE framework_key = 'popia';

INSERT INTO public.document_checklists (framework_key, content_pack_id, slot_key, name, category, required, sort, description)
SELECT 'popia', cp.id, x.slot_key, x.name, x.category, x.required, x.sort, x.description
FROM (SELECT id FROM public.content_packs WHERE practice_id IS NULL AND framework_key='popia' AND version=1) cp,
(VALUES
  -- Phase 1 — Governance & Accountability
  ('io_appointment','Information Officer appointment letter','governance',true,10,'Signed IO designation (POPIA requires every responsible party to designate one).'),
  ('io_registration','Information Regulator registration confirmation','governance',true,20,'IO registered on the IR e-portal.'),
  ('deputy_io','Deputy IO appointment letter(s)','governance',false,30,'Delegated authority for larger organisations (51+ users).'),
  ('io_role_desc','IO role description','governance',false,40,'Documented IO duties and authority.'),
  ('governance_matrix','Governance responsibility matrix','governance',false,50,'Who owns privacy/security responsibilities.'),
  ('risk_register','Privacy & security risk register','register',true,60,'Maintained risk register with owner and treatment plans.'),
  -- Phase 2 — Data mapping & registers
  ('pi_inventory','Personal Information inventory / type register','register',true,70,'All categories of personal information processed.'),
  ('special_pi_register','Special Personal Information register','register',true,80,'Special PI (health, race, biometrics…) with justification.'),
  ('data_subject_categories','Data subject category list','register',false,90,'Employees, customers, suppliers, applicants, visitors.'),
  ('data_flow','Data flow diagram','register',false,100,'How personal information enters, moves and exits the business.'),
  ('asset_register','Information asset register','register',true,110,'Systems/apps/databases holding PI, classified by sensitivity.'),
  ('access_matrix','Access rights matrix','register',false,120,'Who can access which systems (least privilege).'),
  ('lawful_basis_register','Lawful basis register','register',true,130,'Lawful basis for processing each PI category.'),
  ('retention_schedule','Data retention & disposal schedule','policy',true,140,'Retention periods and secure deletion (s.14).'),
  ('crossborder_register','Cross-border transfer register','register',false,150,'Offshore processors / international transfers (s.72).'),
  -- Phase 3.1 — Privacy policies (POPIA required)
  ('privacy_policy','Privacy Policy (external, published)','policy',true,160,'Public-facing processing policy, management-approved.'),
  ('paia_manual','PAIA Manual (s.51, published)','governance',true,170,'Mandatory manual for all private bodies, published on the website.'),
  ('employee_privacy_notice','Employee Privacy Notice','notice',true,180,'HR/payroll/monitoring notice, acknowledged by staff.'),
  ('internal_privacy_policy','Internal Privacy Policy','policy',true,190,'Staff data-handling obligations and breach-reporting duties.'),
  ('consent_records','Consent form templates & consent register','register',true,200,'Valid POPIA consent capture, withdrawal and records.'),
  ('dsr_procedure','Data Subject Request procedure & form','procedure',true,210,'Access/correction/deletion/objection handling (30-day clock).'),
  -- Phase 5 — Third-party & DSR operations
  ('supplier_register','Supplier / operator register','register',true,220,'Operators processing PI, with contract status.'),
  ('operator_agreements','Operator Agreements / DPAs (signed)','agreement',true,230,'s.20/21 written contracts with every operator.'),
  ('crossborder_assessment','Cross-border transfer assessment','agreement',false,240,'s.72 protections per offshore supplier.'),
  ('dsr_log','DSR tracking log','register',false,250,'Request received/type/action/response-date log.'),
  ('dsr_identity_sop','DSR identity-verification SOP','procedure',false,260,'Verify requester identity before disclosure/deletion.'),
  -- Phase 6 — Incident response & monitoring
  ('breach_procedure','Breach notification procedure & templates','procedure',true,270,'IR notification within 72h; data-subject notification (s.22).'),
  ('breach_register','Breach register','register',true,280,'All actual and suspected breaches, assessment and actions.'),
  ('paia_annual_report','PAIA annual report (if required)','governance',false,290,'Submitted to the Information Regulator on request.'),
  -- Training
  ('io_training','IO training completion certificate','register',false,300,'IO trained on POPIA obligations and breach handling.'),
  ('staff_training_log','Staff privacy & security training log','register',true,310,'100% staff training completion evidence.')
) AS x(slot_key,name,category,required,sort,description);

COMMIT;
