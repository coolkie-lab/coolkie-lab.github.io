# Coolkie

Site de commande en ligne et espace de gestion de Coolkie (pâte à cookies surgelée, Bruxelles).

- `index.html` : boutique et espace client (compte avec pseudo, retrait à Uccle ou Woluwe, paiement au retrait, chat).
- `gestion.html` : espace de gestion (commandes, stock, production, clients, messages, chiffres et budget annuel).
- `config.js` : URL et clé publique Supabase, points de retrait.
- `supabase/schema.sql` : base de données à installer une fois dans Supabase (v10 : alerte WhatsApp CallMeBot à chaque commande, réglée dans gestion > Mode dev).
- `img/` : photos.
- `CNAME` : domaine du site (coolkie-lab.be). coolkie-lab.com redirige vers lui depuis OVHcloud.
