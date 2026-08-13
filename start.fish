set -l plugin_root $argv[1]
set -l demo_root $argv[2]
set -l socket $argv[3]
set -l start_gate $argv[4]
set -l nvim $argv[5]
set -l text \
	'lingua-motion.nvim  🌏✨📝' \
	'Apple NLTokenizer motions for multilingual prose  📸💬🌈' \
	'' \
	'# MULTILINGUAL  `7w` · `2b` · `2e` · `ge` · `viw` · `vaw`' \
	'東京のカフェ☕️でSeoulの친구👋と中文メニュー📖を読み、sushi🍣をシェアします🚲✨🌈。' \
	'' \
	'# JAPANESE LONGFORM  `12w` · `v3aw` · `c4aw`' \
	'朝焼け🌅の渋谷を歩きながら新しいアイデア💡をノート📓に書き留め、静かな喫茶店☕️で試作品💻を丁寧に仕上げ、編集者へ原稿を送ります💌✨。' \
	'' \
	'# KOREAN LONGFORM  `9w` · `v2aw` · `c3aw`' \
	'아침 햇살🌞을 받으며 조용한 골목🚶을 걷고, 새로운 아이디어💡를 공책📓에 적은 뒤 편집자에게 원고를 보냅니다💌✨.' \
	'' \
	'# CHINESE LONGFORM  `10w` · `v2aw` · `c3aw`' \
	'清晨🌅沿着安静的街道散步🚶，把崭新的灵感💡写进笔记本📓，然后认真修改文章并发送给编辑💌✨。' \
	'' \
	'# OPERATOR GOLF  `c2aw` · `d2e` · `d2ge`  (IME: ABC)' \
	'推敲中の文章📝では ひらがな カタカナ 한국어 简体中文 English を細かく整えます✍️🎯✨。' \
	'' \
	'# SENTENCE GOLF  `2)` · `(` · `vis` · `vas` · `cis` · `das`' \
	'今日は東京🗼の喫茶店☕️で라면🍜を食べ、简体中文reviewをシェアします📱💬。 次の古い文は削除します🗑️🔥。 Finally、家🏠でゆっくり休みます🌙🛋️✨！'

cd /tmp
set -gx LINGUA_MOTION_PLUGIN_ROOT $plugin_root
set -gx LINGUA_MOTION_DEMO_ROOT $demo_root
while not test -e $start_gate
	sleep 0.05
end
printf '%s\n' $text | $nvim --listen $socket \
	-c 'lua dofile(vim.env.LINGUA_MOTION_DEMO_ROOT .. "/init.lua")' \
	-
