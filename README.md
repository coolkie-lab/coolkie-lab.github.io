# Coolkie

Site de commande en ligne et espace de gestion de Coolkie (pâte à cookies surgelée, Bruxelles).

- `index.html` : boutique et espace client (compte avec pseudo, retrait à Uccle ou Woluwe, paiement au retrait, chat).
- `gestion.html` : espace de gestion (commandes, stock, production, clients, messages, chiffres et budget annuel).
- `config.js` : URL et clé publique Supabase, points de retrait.
- `supabase/schema.sql` : base de données à installer une fois dans Supabase.
- `supabase/functions/push-commande/` : fonction Supabase (Edge Function) qui envoie une notification push aux admins à chaque nouvelle commande. Activation par appareil dans gestion > Mode dev.
- `gestion.webmanifest`, `sw.js` : gestion installable sur l'écran d'accueil et notifications.
- `img/` : photos.
- `CNAME` : domaine du site (coolkie-lab.be). coolkie-lab.com redirige vers lui depuis OVHcloud.
