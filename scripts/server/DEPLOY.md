# Deploy ve bağımlılık kurulumu

Normal güncelleme komutu:

```bash
bash /opt/kyrox/kyrox-fair-crm/scripts/server/deploy-all.sh
```

Deploy önce GitHub'daki kodu çeker. CRM frontend ve Fair Stand bağımlılıkları
`npm ci` ile repoda kayıtlı lockfile sürümlerinden kurulur. Yeni commit'teki yeni
paketler de kurulur; sunucuda yeni sürüm seçilmez ve lockfile yeniden üretilmez.
`package.json` ile lockfile uyumsuzsa kurulum durur; düzeltme geliştirme ortamında
yapılıp PR üzerinden gönderilmelidir.

CRM frontend kurulumu ve build sonrasında paket dosyalarının değişmediği de
kontrol edilir. Başarılı deploy takip edilen dosyalarda değişiklik bırakmamalıdır.

Eski `npm install` adımından kalan lockfile değişikliği varsa önce farkı inceleyin.
Yalnız kurulum kaynaklı olduğu doğrulanan dosyayı `git stash push --
frontend/package-lock.json` ile yedekleyip deploy'u tekrar çalıştırın. Bu yedeği
başarılı deploy sonrasında otomatik geri uygulamayın.
