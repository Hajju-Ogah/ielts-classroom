SHEKINAH IELTS CLASSROOM
========================

Start with Setup-Guide.pdf. It takes about an hour, once, on a laptop with Google Chrome.

What is in this folder
----------------------
1-upload-to-github/              The website. Upload everything inside this folder to a new GitHub
                                 repository (Guide, Part E), then paste your 3 keys into config.js.

2-supabase-setup.sql             Database, security rules, marking functions and all 14 days of lessons.
                                 Paste into Supabase > SQL Editor and click Run (Guide, Part B).
                                 Do NOT upload this file to GitHub: it contains the answer keys.

3-video-function-jaas-token.ts   The video-call pass. Paste into Supabase > Edge Functions as a new
                                 function named  jaas-token  (Guide, Part D).

Setup-Guide.pdf / .docx          Step-by-step instructions, daily routine and troubleshooting.

Order of setup
--------------
A  Create accounts: GitHub, Supabase, JaaS (jaas.8x8.vc)
B  Supabase: new project > add 2 users > run 2-supabase-setup.sql > run the make-tutor lines > copy URL + key
C  JaaS: copy App ID > generate API key pair > download private key > copy Key ID
D  Supabase Edge Function "jaas-token" (JWT verification OFF) + 3 secrets
E  GitHub: new public repo > upload website files > edit config.js > Settings > Pages > main / (root)
F  Test with two devices, then send Dickson his link and password

Marking with Claude
-------------------
Mark page > Export for Claude > attach the file in a Claude chat ("Mark this IELTS work and give me
the marking file") > Import marking > check, add pronunciation scores > Release to student.
