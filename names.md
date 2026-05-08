# Sanskrit Names Library — Chaldean 6

All names in the Lochan ecosystem use **Chaldean numerology value 6**.

**Chaldean Map:** A=1, B=2, C=3, D=4, E=5, F=8, G=3, H=5, I=1, J=1, K=2, L=3, M=4, N=5, O=7, P=8, Q=1, R=2, S=3, T=4, U=6, V=6, W=6, X=5, Y=1, Z=7

**Rule:** Sum all letter values, then reduce to single digit. Target = **6**.

---

## 2026-04-24 — Framework Avatar Primitive (Approved Plan)

Plan: `~/.claude/plans/concurrent-riding-neumann.md` (backup: `claude/lochan/plans/framework-vyakti-avatar-primitives.md`).

Three-word naming decision, all Chaldean-6:

| Term | Sanskrit | Chaldean | Role in Lochan |
|---|---|---|---|
| **Vyakti** | व्यक्ति | V(6)+Y(1)+A(1)+K(2)+T(4)+I(1)=15→**6** | Layer namespace — `vyakti.*` for person-related framework primitives (avatar, overlay, consent_gate) |
| **Avatar** | अवतार | A(1)+V(6)+A(1)+T(4)+A(1)+R(2)=15→**6** | Shared archetypal-lens primitive (`vyakti.avatar`) — package-contributed, sealed, versioned. Many users activate the same avatar (recruiter, per-diem-recruiter, nurse, MH, emergency) |
| **Vaktaa** | वक्ता | V(6)+A(1)+K(2)+T(4)+A(1)+A(1)=15→**6** | **PARKED** — was proposed as per-user digital twin / spokesperson. Deferred to v2 pending user-sovereignty use cases (cross-tenant federation, peer-to-peer discovery). If v2 goes forward, Vaktaa builds on top of Avatar with no primitive change |

**Naming collision sweep (F1):** existing `User.avatar_url` (profile-picture URL in `trishul/sepoy/models/user.py:25`) is renamed to `User.profile_image_url` — complete-tree sweep, covers 34 MUI frontend references + serializers + chat service + layout detector + schema enricher. MUI `<Avatar>` React component is unambiguous by import and unchanged.

**Patent scaffold:** FP12 continuation covering Avatar primitive as conjunctive framework-architecture claim (6 claims). File provisional before 2026-07-19.

---

## CANONICAL SNAPSHOT — 2026-04-21

Use this section as source of truth. Some legacy sections below are historical.

### Current Framework Package Set (`framework/lochan/packages/`)

- `muulam` (renamed from `lochan-core`, done)
- `abhilekh` (renamed from `pycrud`, done)
- `anvaya` (lifecycle package; Nexus branding retained)
- `gyanam` (renamed from `lochan-ai`, done)
- `mandi` (renamed from `lochan-mandi`, done)
- `trishul`, `shabd`, `vicharan`, `pratibha`, `pratyuttar`, `tarkan`, `duta`, `flow`, `suchana`, `viniyog`, `lighthouse`, `litevault`

### Current Common Packages (`mandi/common/`)

- `ankana`, `chintan`, `dravya`, `guna`, `khoj`, `koshagar`, `nishchay`, `prapti`, `sauda`, `seva`, `shodh`, `sulka`, `vahak`

### Current Domain Packages (`mandi/domain/`)

- `autonex`, `bharti`, `covera`, `duta`, `flow`, `grahaka`, `lifelight`, `longterm`, `mediaserver`, `pestpro`, `realtor` (Lokavit brand), `regsevak`, `vyaparam`

### Rename Status (Corrected)

| Current | New Name | Status | Note |
|---|---|---|---|
| `lochan-core` | `muulam` | DONE | Applied |
| `lochan-ai` | `gyanam` | DONE | Applied |
| `lochan-mandi` | `mandi` | DONE | Applied |
| `pycrud` | `abhilekh` | DONE | Applied |
| `nexus` | `samsara` | NOT APPLIED | `anvaya` package with Nexus branding |

## CANDIDATE — Theme Name Bank (Chaldean 6)

### Representative

| Name | Sanskrit | Meaning | Chaldean Calc |
|---|---|---|---|
| **Duta** | दूत | Messenger, representative | D(4)+U(6)+T(4)+A(1)=15→**6** |
| **Vaktaa** | वक्ता | Speaker, spokesperson — **PARKED 2026-04-24** pending v2 user-sovereignty use cases (see top of file) | V(6)+A(1)+K(2)+T(4)+A(1)+A(1)=15→**6** |
| **Sakshi** | साक्षी | Witness, observer | S(3)+A(1)+K(2)+S(3)+H(5)+I(1)=15→**6** |

### Persona

| Name | Sanskrit | Meaning | Chaldean Calc |
|---|---|---|---|
| **Vyakti** | व्यक्ति | Person, individual — **ADOPTED 2026-04-24** as layer namespace `vyakti.*` (see top of file) | V(6)+Y(1)+A(1)+K(2)+T(4)+I(1)=15→**6** |
| **Avatar** | अवतार | Incarnation / archetypal lens — **ADOPTED 2026-04-24** as persona primitive `vyakti.avatar` (see top of file) | A(1)+V(6)+A(1)+T(4)+A(1)+R(2)=15→**6** |
| **Abhivyakti** | अभिव्यक्ति | Expression, outward persona | A(1)+B(2)+H(5)+I(1)+V(6)+Y(1)+A(1)+K(2)+T(4)+I(1)=24→**6** |
| **Akar** | आकार | Form, shape, profile | A(1)+K(2)+A(1)+R(2)=6→**6** |
| **Samjna** | संज्ञा | Identity, designation | S(3)+A(1)+M(4)+J(1)+N(5)+A(1)=15→**6** |

### Chat

| Name | Sanskrit | Meaning | Chaldean Calc |
|---|---|---|---|
| **Vicharan** | विचरण | Deliberative exchange | V(6)+I(1)+C(3)+H(5)+A(1)+R(2)+A(1)+N(5)=24→**6** |
| **Pratyuttar** | प्रत्युत्तर | Reply, response | P(8)+R(2)+A(1)+T(4)+Y(1)+U(6)+T(4)+T(4)+A(1)+R(2)=33→**6** |
| **Vaarta** | वार्ता | Dialogue, talk | V(6)+A(1)+A(1)+R(2)+T(4)+A(1)=15→**6** |

### Conversation

| Name | Sanskrit | Meaning | Chaldean Calc |
|---|---|---|---|
| **Vaarta** | वार्ता | Conversation, discourse | V(6)+A(1)+A(1)+R(2)+T(4)+A(1)=15→**6** |
| **Vicharan** | विचरण | Deliberation | V(6)+I(1)+C(3)+H(5)+A(1)+R(2)+A(1)+N(5)=24→**6** |
| **Smriti** | स्मृति | Recollection thread/history | S(3)+M(4)+R(2)+I(1)+T(4)+I(1)=15→**6** |

### Vault

| Name | Sanskrit | Meaning | Chaldean Calc |
|---|---|---|---|
| **Koshagar** | कोशागार | Treasury keeper, vault | K(2)+O(7)+S(3)+H(5)+A(1)+G(3)+A(1)+R(2)=24→**6** |
| **LiteVault** | — | Encrypted storage vault | L(3)+I(1)+T(4)+E(5)+V(6)+A(1)+U(6)+L(3)+T(4)=33→**6** |
| **Smriti** | स्मृति | Memory vault/archive | S(3)+M(4)+R(2)+I(1)+T(4)+I(1)=15→**6** |

---

## IN USE — Framework & Project

| Name | Sanskrit | Meaning | Chaldean Calc | Location |
|------|----------|---------|---------------|----------|
| **Gyanam** | ज्ञानम् | Knowledge, wisdom | G(3)+Y(1)+A(1)+N(5)+A(1)+M(4)=15→**6** | Project root |
| **Lochan** | लोचन | Eye, vision, insight | L(3)+O(7)+C(3)+H(5)+A(1)+N(5)=24→**6** | `framework/lochan/` |
| **Mandi** | मण्डी | Marketplace, bazaar | M(4)+A(1)+N(5)+D(4)+I(1)=15→**6** | `mandi/` |

## IN USE — Core Framework Packages (lochan/packages/)

| Name | Sanskrit | Meaning | Chaldean Calc | Package |
|------|----------|---------|---------------|---------|
| **Jharokha** | झरोखा | Window, latticed opening | J(1)+H(5)+A(1)+R(2)+O(7)+K(2)+H(5)+A(1)=24→**6** | Connector hub (LLM registration, agent card, MCP) |
| **Alankar** | अलंकार | Ornament, embellishment | A(1)+L(3)+A(1)+N(5)+K(2)+A(1)+R(2)=15→**6** | Custom metadata fields |
| **Shabd** | शब्द | Word, sound | S(3)+H(5)+A(1)+B(2)+D(4)=15→**6** | Translation & i18n |
| **Vicharan** | विचरण | Exploration, deliberation | V(6)+I(1)+C(3)+H(5)+A(1)+R(2)+A(1)+N(5)=24→**6** | Team chat with AI |
| **Pratyuttar** | प्रत्युत्तर | Reply, response | P(8)+R(2)+A(1)+T(4)+Y(1)+U(6)+T(4)+T(4)+A(1)+R(2)=33→**6** | Conversational AI |
| **Pratibha** | प्रतिभा | Brilliance, intelligence | P(8)+R(2)+A(1)+T(4)+I(1)+B(2)+H(5)+A(1)=24→**6** | User-defined schemas & reports |
| **Roop** | रूप | Form, appearance, beauty | R(2)+O(7)+O(7)+P(8)=24→**6** | Theme & visual experience layer |
| **Rupayan** | रूपायन | Modeling, giving form | R(2)+U(6)+P(8)+A(1)+Y(1)+A(1)+N(5)=24→**6** | Frontend page composition & templating |
| **Tarkan** | तर्कण | Reasoning, conjecture, inference | T(4)+A(1)+R(2)+K(2)+A(1)+N(5)=15→**6** | Simulation & BI engine |

## IN USE — Trishul Security Sub-Packages (lochan/packages/trishul/)

| Name | Sanskrit | Meaning | Chaldean Calc | Sub-Package |
|------|----------|---------|---------------|-------------|
| **Trishul** | त्रिशूल | Trident, three-pronged | T(4)+R(2)+I(1)+S(3)+H(5)+U(6)+L(3)=24→**6** | Security framework |
| **Sepoy** | सिपाही | Soldier, guard | S(3)+E(5)+P(8)+O(7)+Y(1)=24→**6** | Identity & Auth |
| **Dristi** | दृष्टि | Sight, vision | D(4)+R(2)+I(1)+S(3)+T(4)+I(1)=15→**6** | Row-level scope |
| **Dvaara** | द्वार | Door, gate | D(4)+V(6)+A(1)+A(1)+R(2)+A(1)=15→**6** | Field & resource gate |
| **Niyama** | नियम | Rule, discipline | N(5)+I(1)+Y(1)+A(1)+M(4)+A(1)=13→**4** | Security policies |
| **Bhoomika** | भूमिका | Role, character | B(2)+H(5)+O(7)+O(7)+M(4)+I(1)+K(2)+A(1)=29→**2** | Persona-based RBAC |

> Note: Niyama (4) and Bhoomika (2) are NOT Chaldean 6 — adopted before naming convention was strict.

## IN USE — Mandi Common Packages (mandi/common/)

| Name | Sanskrit | Meaning | Chaldean Calc | Package |
|------|----------|---------|---------------|---------|
| **Shodh** | शोध | Research, purification | S(3)+H(5)+O(7)+D(4)+H(5)=24→**6** | Lead qualification engine |
| **Khoj** | खोज | Search, investigation | K(2)+H(5)+O(7)+J(1)=15→**6** | Social profile intelligence |
| **Suchana** | सूचना | Information, notification | S(3)+U(6)+C(3)+H(5)+A(1)+N(5)+A(1)=24→**6** | Multi-channel messaging |
| **Ankana** | अंकन | Marking, scoring | A(1)+N(5)+K(2)+A(1)+N(5)+A(1)=15→**6** | Scoring + signal detection |
| **Guna** | गुण | Quality, attribute | G(3)+U(6)+N(5)+A(1)=15→**6** | Data quality + dedup |
| **Nishchay** | निश्चय | Certainty, determination | N(5)+I(1)+S(3)+H(5)+C(3)+H(5)+A(1)+Y(1)=24→**6** | Credential lifecycle |
| **Bharti** | भर्ती | Enrollment, admission, recruitment | B(2)+H(5)+A(1)+R(2)+T(4)+I(1)=15→**6** | Reusable enrollment/registration engine (extracted from regsevak) |
| **Chintan** | चिन्तन | Contemplation, thinking | C(3)+H(5)+I(1)+N(5)+T(4)+A(1)+N(5)=24→**6** | Training & CE tracking |
| **Sauda** | सौदा | Deal, transaction, bargain | S(3)+A(1)+U(6)+D(4)+A(1)=15→**6** | Sales Pipeline — leads, quotes, opportunities |
| **Seva** | सेवा | Service, devotion | S(3)+E(5)+V(6)+A(1)=15→**6** | Service Ops — work orders, scheduling, dispatch |
| **Sulka** | शुल्क | Fee, toll, charge | S(3)+U(6)+L(3)+K(2)+A(1)=15→**6** | Billing — invoicing, payments, refunds |
| **Prapti** | प्राप्ति | Receipt, attainment, earning | P(8)+R(2)+A(1)+P(8)+T(4)+I(1)=24→**6** | Commission — statements, splits, reconciliation |

## IN USE — Domain Packages (mandi/domain/)

| Name | Sanskrit | Meaning | Chaldean Calc | Package |
|------|----------|---------|---------------|---------|
| **Grahaka** | ग्राहक | Customer, client | G(3)+R(2)+A(1)+H(5)+A(1)+K(2)+A(1)=15→**6** | AI-first agentic CRM |
| **Duta** | दूत | Messenger, ambassador | D(4)+U(6)+T(4)+A(1)=15→**6** | CRM marketing / integrations |
| **Viniyog** | विनियोग | Allocation, assignment | V(6)+I(1)+N(5)+I(1)+Y(1)+O(7)+G(3)=24→**6** | Resource allocation engine (framework) |
| **Vyaparam** | व्यापारम् | Commerce, business | V(6)+Y(1)+A(1)+P(8)+A(1)+R(2)+A(1)+M(4)=24→**6** | Commerce & payments (domain) |
| **Lokavit** | लोकवित् | Knower of realms | L(3)+O(7)+K(2)+A(1)+V(6)+I(1)+T(4)=24→**6** | Real estate CMA/MLS |

## IN USE — Domain Sub-Packages

| Name | Sanskrit | Meaning | Chaldean Calc | Parent → Sub-Package |
|------|----------|---------|---------------|----------------------|
| **Samjna** | संज्ञा | Mutual understanding | S(3)+A(1)+M(4)+J(1)+N(5)+A(1)=15→**6** | Grahaka → AI customer service |
| **Shravana** | श्रवण | Listening, hearing | S(3)+H(5)+R(2)+A(1)+V(6)+A(1)+N(5)+A(1)=24→**6** | Grahaka → Sales intelligence |
| **Sakshi** | साक्षी | Witness, observer | S(3)+A(1)+K(2)+S(3)+H(5)+I(1)=15→**6** | Longterm → MH compact intel |
| **Sanjaal** | संजाल | Network, mesh | S(3)+A(1)+N(5)+J(1)+A(1)+A(1)+L(3)=15→**6** | Longterm → Insurance paneling |
| **Ganita** | गणित | Mathematics, numerology | G(3)+A(1)+N(5)+I(1)+T(4)+A(1)=15→**6** | LifeLight → Numerology |
| **Jyothishyam** | ज्योतिष्यम् | Astrology, light science | J(1)+Y(1)+O(7)+T(4)+H(5)+I(1)+S(3)+H(5)+Y(1)+A(1)+M(4)=33→**6** | LifeLight → Vedic astrology |

## IN USE — Tools

| Name | Sanskrit | Meaning | Chaldean Calc | Location |
|------|----------|---------|---------------|----------|
| **Vardhan** | वर्धन | Growth, enhancement | V(6)+A(1)+R(2)+D(4)+H(5)+A(1)+N(5)=24→**6** | `tools/vardhan/` — Legacy migration |
| **Daksh** | दक्ष | Skilled, capable, competent | D(4)+A(1)+K(2)+S(3)+H(5)=15→**6** | `tools/daksh/` — Dev toolkit (build, validate, evolve, deploy) |

---

## CANDIDATE — Dev Toolkit (replacing "forge")

Looking for a short, verb-like Sanskrit name for the framework development toolkit (build, validate, evolve, deploy, scaffold, inspect).

**Requirements:** Chaldean 6, short (4-6 chars), sounds like an action/verb, works as CLI prefix.

| Name | Sanskrit | Meaning | Chars | Chaldean Calc | CLI Feel |
|------|----------|---------|-------|---------------|----------|
| **Daksh** | दक्ष | Skilled, capable, competent | 5 | D(4)+A(1)+K(2)+S(3)+H(5)=15→**6** | `daksh evolve`, `daksh inspect`, `daksh scaffold` |
| **Kruti** | कृति | Creation, work, composition | 5 | K(2)+R(2)+U(6)+T(4)+I(1)=15→**6** | `kruti evolve`, `kruti build` |
| **Roop** | रूप | To form, to shape | 4 | R(2)+O(7)+O(7)+P(8)=24→**6** | `roop evolve`, `roop scaffold` |
| **Akar** | आकार | To shape, to form | 4 | A(1)+K(2)+A(1)+R(2)=6→**6** | `akar evolve`, `akar build` |
| **Sajj** | सज्ज | To equip, to arm | 4 | S(3)+A(1)+J(1)+J(1)=6→**6** | `sajj deploy`, `sajj scaffold` |
| **Utkar** | उत्कर | To elevate, to improve | 5 | U(6)+T(4)+K(2)+A(1)+R(2)=15→**6** | `utkar evolve`, `utkar heal` |
| **Yojan** | योजन | Joining, assembling | 5 | Y(1)+O(7)+J(1)+A(1)+N(5)=15→**6** | `yojan deploy`, `yojan integrate` |
| **Palak** | पालक | Nurturer, maintainer | 5 | P(8)+A(1)+L(3)+A(1)+K(2)=15→**6** | `palak evolve`, `palak heal` |
| **Ghadhan** | घडन | Forging, shaping, molding | 7 | G(3)+H(5)+A(1)+D(4)+H(5)+A(1)+N(5)=24→**6** | `ghadhan evolve` (literal "forge") |
| **Taadit** | ताडित | Hammered, beaten into shape | 6 | T(4)+A(1)+A(1)+D(4)+I(1)+T(4)=15→**6** | `taadit evolve` (forge metaphor) |
| **Nirmak** | निर्माक | Builder, maker | 6 | N(5)+I(1)+R(2)+M(4)+A(1)+K(2)=15→**6** | `nirmak scaffold`, `nirmak build` |
| **Chetana** | चेतना | Consciousness, awareness | 7 | C(3)+H(5)+E(5)+T(4)+A(1)+N(5)+A(1)=24→**6** | `chetana evolve` (too long?) |

**CHOSEN:** **Daksh** — deployed at `tools/daksh/`, repo: `github.com/ssnukala/lochan-daksh`

**Context:** Lochan sees (runtime) → Daksh acts (dev toolkit) → Vardhan transforms (migration)

---

## CONSIDERED BUT NOT CHOSEN (Available)

| Name | Sanskrit | Meaning | Chaldean Calc | Context |
|------|----------|---------|---------------|---------|
| **Lokpal** | लोकपाल | World-protector | L(3)+O(7)+K(2)+P(8)+A(1)+L(3)=24→**6** | Framework name candidate (Lochan chosen instead) |
| **Matrika** | मातृका | Source pattern, matrix | M(4)+A(1)+T(4)+R(2)+I(1)+K(2)+A(1)=15→**6** | Terminology service candidate (Samjna chosen instead) |

## NAMED BUT NOT YET BUILT (Available for Grahaka sub-packages)

| Name | Sanskrit | Meaning | Chaldean Calc | Planned For |
|------|----------|---------|---------------|-------------|
| **Margam** | मार्गम् | Path, way | M(4)+A(1)+R(2)+G(3)+A(1)+M(4)=15→**6** | Next Best Action engine |
| **Vilasa** | विलास | Sport, play | V(6)+I(1)+L(3)+A(1)+S(3)+A(1)=15→**6** | Gamification |
| **Spardha** | स्पर्धा | Competition | S(3)+P(8)+A(1)+R(2)+D(4)+H(5)+A(1)=24→**6** | Competitive intelligence |
| **Arthik** | आर्थिक | Economic, financial | A(1)+R(2)+T(4)+H(5)+I(1)+K(2)=15→**6** | Revenue intelligence |
| **Vaarta** | वार्ता | Conversation, news | V(6)+A(1)+A(1)+R(2)+T(4)+A(1)=15→**6** | Conversation intelligence |
| **Smriti** | स्मृति | Memory, recollection | S(3)+M(4)+R(2)+I(1)+T(4)+I(1)=15→**6** | Playbooks / runbooks |

## NAMED BUT NOT YET BUILT (Vardhan name candidates)

| Name | Sanskrit | Meaning | Chaldean Calc | Context |
|------|----------|---------|---------------|---------|
| **Navikaran** | नवीकरण | Renewal, modernization | N(5)+A(1)+V(6)+I(1)+K(2)+A(1)+R(2)+A(1)+N(5)=24→**6** | Migration tool candidate |
| **Unnayan** | उन्नयन | Elevation, upgrade | U(6)+N(5)+N(5)+A(1)+Y(1)+A(1)+N(5)=24→**6** | Migration tool candidate |
| **Vivartaka** | विवर्तक | Transformer | V(6)+I(1)+V(6)+A(1)+R(2)+T(4)+A(1)+K(2)+A(1)=24→**6** | Migration tool candidate |
| **Sanvardhan** | संवर्धन | Cultivation, nurturing | S(3)+A(1)+N(5)+V(6)+A(1)+R(2)+D(4)+H(5)+A(1)+N(5)=33→**6** | Migration tool candidate |
| **Ujjvalan** | उज्ज्वलन | Illumination, brightening | U(6)+J(1)+J(1)+V(6)+A(1)+L(3)+A(1)+N(5)=24→**6** | Migration tool candidate |

## IN USE — Daksh Sub-Systems

| Name | Sanskrit | Meaning | Chaldean Calc | Sub-System |
|------|----------|---------|---------------|------------|
| **Janch** | जांच | Test, examination, inspection | J(1)+A(1)+N(5)+C(3)+H(5)=15→**6** | Agentic testing — validation, test gen, test execution, signal emission |

---

## NAMED BUT NOT YET BUILT (Agent Gap Analysis — 2026-04-15)

Identified from wrap target analysis. Needed for 85-90% entity coverage across wrapped apps.

| Name | Sanskrit | Meaning | Chaldean Calc | Planned For |
|------|----------|---------|---------------|-------------|
| **Dravya** | द्रव्य | Substance, material, goods | D(4)+R(2)+A(1)+V(6)+Y(1)+A(1)=15→**6** | STOCK — inventory, warehouses, stock levels, adjustments |
| **Koshagar** | कोशागार | Treasury keeper, procurer | K(2)+O(7)+S(3)+H(5)+A(1)+G(3)+A(1)+R(2)=24→**6** | BUY — vendors, POs, procurement, receiving |
| **Vahak** | वाहक | Carrier, transporter | V(6)+A(1)+H(5)+A(1)+K(2)=15→**6** | MOVE — shipments, fulfillment, carriers, tracking |

## NAMED BUT NOT YET BUILT — Marketing / Outreach / Generic (2026-05-08)

Computed during the marketing-package naming session (duta-marketing split: duta returns to protocol-only; marketing needs a new home). All entries verified Chaldean = 6.

### Strong fit for marketing / outreach / announcement

| Name | Sanskrit | Meaning | Chaldean Calc | Notes |
|------|----------|---------|---------------|-------|
| **Khyaapan** | ख्यापन | Announcement, proclamation, making known | K(2)+H(5)+Y(1)+A(1)+A(1)+P(8)+A(1)+N(5)=24→**6** | Strongest semantic match — "the act of making known." Pairs with Duta (compose→carry) |
| **Lekh** | लेख | Writing, inscription, document, message | L(3)+E(5)+K(2)+H(5)=15→**6** | **CHOSEN 2026-05-08** for the marketing package (replaces duta's marketing scaffolding; pairs with Duta as Lekh-composes / Duta-carries). Sibling root √लिख् with Abhilekh. See RESERVED section below. |
| **Aamantran** | आमंत्रण | Invitation | A(1)+A(1)+M(4)+A(1)+N(5)+T(4)+R(2)+A(1)+N(5)=24→**6** | Fits agent-first paradigm — invite agents to engage |
| **Stava** | स्तव | Praise, hymn, eulogy | S(3)+T(4)+A(1)+V(6)+A(1)=15→**6** | Marketing as praise; slightly archaic feel |
| **Khyaati** | ख्याति | Fame, reputation | K(2)+H(5)+Y(1)+A(1)+A(1)+T(4)+I(1)=15→**6** | Brand-building flavor |
| **Prerana** | प्रेरणा | Inspiration, motivation | P(8)+R(2)+E(5)+R(2)+A(1)+N(5)+A(1)=24→**6** | Motivational marketing framing |
| **Sansar** | संसार | World, all-pervading | S(3)+A(1)+N(5)+S(3)+A(1)+R(2)=15→**6** | "Reach the world" framing |

### Available — weaker fit but valid (noted for future slots)

| Name | Sanskrit | Meaning | Chaldean Calc | Notes |
|------|----------|---------|---------------|-------|
| **Dhama** | धाम | Abode, glory, splendor | D(4)+H(5)+A(1)+M(4)+A(1)=15→**6** | More "abode" than outreach |
| **Varna** | वर्ण | Color, description, depiction | V(6)+A(1)+R(2)+N(5)+A(1)=15→**6** | **CAUTION:** also means caste — loaded connotation |
| **Vyakta** | व्यक्त | Manifest, expressed | V(6)+Y(1)+A(1)+K(2)+T(4)+A(1)=15→**6** | **CAUTION:** semantic conflict with Vyakti (व्यक्ति) — already in use as `vyakti.*` namespace |

### Short generic Sanskrit roots (3 letters, Chaldean 6)

Catalogued for completeness — wrong category for marketing, but available for other slots if a 3-letter name is ever needed:

| Name | Sanskrit | Meaning | Chaldean Calc | Notes |
|------|----------|---------|---------------|-------|
| **Mod** | मोद | Joy, pleasure | M(4)+O(7)+D(4)=15→**6** | 3 letters — shortest possible Chaldean-6 Sanskrit |
| **Lab** | लाभ | Profit, gain | L(3)+A(1)+B(2)=**6** | 3 letters; commercial/transactional |
| **Bal** | बल | Strength, power | B(2)+A(1)+L(3)=**6** | 3 letters; force/strength flavor |
| **Kal** | काल | Time, death | K(2)+A(1)+L(3)=**6** | 3 letters; **CAUTION** — काल also means death/Yama |

### General-purpose Sanskrit Chaldean-6 names (action / quality / lifecycle)

Additional verified candidates from broader semantic scan — available for any future package, sub-system, or capability slot.

| Name | Sanskrit | Meaning | Chaldean Calc | Best fit |
|------|----------|---------|---------------|----------|
| **Jaagaran** | जागरण | Awakening, vigilance, watchfulness | J(1)+A(1)+A(1)+G(3)+A(1)+R(2)+A(1)+N(5)=15→**6** | Monitoring / alerting / wake-up service |
| **Arambh** | आरंभ | Commencement, beginning, initiation | A(1)+R(2)+A(1)+M(4)+B(2)+H(5)=15→**6** | Bootstrap / initialization / scaffold-start |
| **Nirnay** | निर्णय | Decision, judgment, conclusion | N(5)+I(1)+R(2)+N(5)+A(1)+Y(1)=15→**6** | Decision engine / verdict resolver |
| **Adhyas** | अध्यास | Super-imposition (Vedanta term) — layered overlay | A(1)+D(4)+H(5)+Y(1)+A(1)+S(3)=15→**6** | Overlay / persona-overlay / layering primitive |
| **Akhyan** | आख्यान | Narrative, story, account | A(1)+K(2)+H(5)+Y(1)+A(1)+N(5)=15→**6** | Storytelling / narration service / case-history |
| **Posha** | पोष | Nourishment, sustenance, care | P(8)+O(7)+S(3)+H(5)+A(1)=24→**6** | Nurturing / sustainability / customer-success |
| **Spasht** | स्पष्ट | Clear, explicit, evident | S(3)+P(8)+A(1)+S(3)+H(5)+T(4)=24→**6** | Transparency / clarity / explainability |
| **Vinaya** | विनय | Humility, modesty, discipline | V(6)+I(1)+N(5)+A(1)+Y(1)+A(1)=15→**6** | Discipline / governance / modest-defaults |
| **Sadhya** | साध्य | Achievable goal, what ought to be done | S(3)+A(1)+D(4)+H(5)+Y(1)+A(1)=15→**6** | Goals / OKRs / target-state planner |
| **Antim** | अंतिम | Final, ultimate, last | A(1)+N(5)+T(4)+I(1)+M(4)=15→**6** | Terminal state / finalize / commit-stage |
| **Nivritti** | निवृत्ति | Cessation, withdrawal, retirement | N(5)+I(1)+V(6)+R(2)+I(1)+T(4)+T(4)+I(1)=24→**6** | Deprecation / retirement / sunset |
| **Aastha** | आस्था | Faith, conviction, trust | A(1)+A(1)+S(3)+T(4)+H(5)+A(1)=15→**6** | Trust / credibility / reputation system |
| **Kalpa** | कल्प | Era, eon, ritual procedure | K(2)+A(1)+L(3)+P(8)+A(1)=15→**6** | **CAUTION** — Hindu-cosmology timing connotation |
| **Pooja** | पूजा | Worship, ceremony | P(8)+O(7)+O(7)+J(1)+A(1)=24→**6** | **CAUTION** — religious-ceremony connotation |

## DEFERRED (Future extraction when needed)

| Name | Sanskrit | Meaning | Chaldean Calc | Trigger |
|------|----------|---------|---------------|---------|
| **Chetana** | चेतना | Awareness, consciousness | C(3)+H(5)+E(5)+T(4)+A(1)+N(5)+A(1)=24→**6** | When 2nd domain needs signal detection |

---

## NON-SANSKRIT NAMES (Also Chaldean 6)

These are English/Latin names in the ecosystem that happen to also be Chaldean 6:

| Name | Chaldean Calc | Package |
|------|---------------|---------|
| **Nexus** | N(5)+E(5)+X(5)+U(6)+S(3)=24→**6** | Lifecycle state machine |
| **Lighthouse** | L(3)+I(1)+G(3)+H(5)+T(4)+H(5)+O(7)+U(6)+S(3)+E(5)=42→**6** | Agent dashboard |
| **LiteVault** | L(3)+I(1)+T(4)+E(5)+V(6)+A(1)+U(6)+L(3)+T(4)=33→**6** | Document storage |
| **pyCRUD** | P(8)+Y(1)+C(3)+R(2)+U(6)+D(4)=24→**6** | Schema-driven CRUD |
| **LifeLight** | L(3)+I(1)+F(8)+E(5)+L(3)+I(1)+G(3)+H(5)+T(4)=33→**6** | Vedic sciences domain |
| **Autonex** | A(1)+U(6)+T(4)+O(7)+N(5)+E(5)+X(5)=33→**6** | Auto dealership domain |
| **Flow** | F(8)+L(3)+O(7)+W(6)=24→**6** | Workflow engine |

---

## Quick Reference — Name Availability

**Used (37):** Gyanam, Lochan, Mandi, **Jharokha**, Alankar, Shabd, Vicharan, Pratyuttar, Pratibha, **Rupayan**, Trishul, Sepoy, Dristi, Dvaara, Niyama*, Bhoomika*, Shodh, Khoj, Suchana, Ankana, Guna, Nishchay, Chintan, Grahaka, Duta, Viniyog, Lokavit, Samjna, Shravana, Sakshi, Sanjaal, Vardhan, Daksh, Ganita, Jyothishyam, Janch, **Sauda**, **Seva**, **Sulka**, **Prapti**

**Available — named but unbuilt (11):** Margam, Vilasa, Spardha, Arthik, Vaarta, Smriti, Navikaran, Unnayan, Vivartaka, Sanvardhan, Ujjvalan

**Available — Chaldean-6 candidates added 2026-05-08 (27):** Khyaapan, Aamantran, Khyaati, Prerana, Stava, Sansar, Dhama, Varna*, Vyakta*, Mod, Lab, Bal, Kal*, Jaagaran, Arambh, Nirnay, Adhyas, Akhyan, Posha, Spasht, Vinaya, Sadhya, Antim, Nivritti, Aastha, Kalpa*, Pooja*

**Available — rejected candidates (2):** Lokpal, Matrika

**Deferred (1):** Chetana

**Reserved for assigned future packages (2):** Drasta (cognitive cortex), Lekh (marketing — chosen 2026-05-08)

*\* = Not actually Chaldean 6 (adopted before strict convention)*

## PLANNED RENAMES (Next Session)

| Current | New Name | Sanskrit | Meaning | Chaldean | Status |
|---|---|---|---|---|---|
| `lochan-core` | `muulam` | मूलम् | Root, Foundation | M(4)+U(6)+U(6)+L(3)+A(1)+M(4)=24→**6** | DONE |
| `lochan-ai` | `gyanam` | ज्ञानम् | Knowledge, Wisdom | G(3)+Y(1)+A(1)+N(5)+A(1)+M(4)=15→**6** | DONE |
| `lochan-mandi` | `mandi` | मंडी | Marketplace | Already **6** | DONE |
| `pycrud` | `abhilekh` | अभिलेख | Record, Inscription | A(1)+B(2)+H(5)+I(1)+L(3)+E(5)+K(2)+H(5)=24→**6** | DONE |
| `nexus` | `samsara` | संसार | Cycle of Existence | S(3)+A(1)+M(4)+S(3)+A(1)+R(2)+A(1)=15→**6** | NOT APPLIED (using `anvaya` with Nexus branding) |

## RESERVED FOR FUTURE USE

| Name | Sanskrit | Meaning | Chaldean | Reserved for |
|---|---|---|---|---|
| `drasta` | द्रष्टा | The Seer, The Observer | D(4)+R(2)+A(1)+S(3)+T(4)+A(1)=15→**6** | Cognitive cortex package — local LLM agent (plan: `framework-drasta-local-agent-2026-04-25.md`) |
| `lekh` | लेख | Writing, inscription, document, message | L(3)+E(5)+K(2)+H(5)=15→**6** | Marketing package — replaces duta's marketing scaffolding (chosen 2026-05-08). Pairs with Duta as Lekh-composes / Duta-carries; sibling root √लिख् with Abhilekh |
