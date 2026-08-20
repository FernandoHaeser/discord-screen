/**
 * Equivalente ao `start:fast` para dentro do container: sem menu, sem
 * perguntas, sem rebuild (o build já aconteceu no estágio de imagem) — só
 * abre um túnel descartável e sobe o servidor apontando para ele.
 *
 * `gravar: false` de propósito: o processo roda como usuário `node`, sem
 * permissão de escrita em `/app`, e não há `.env` persistente aqui — quem lê
 * PUBLIC_ORIGIN é o processo do servidor, direto do ambiente que este script
 * repassa a ele (ver `iniciarServidor`), nunca de um arquivo.
 *
 * Endereço novo a cada `docker compose up`/restart, por design (issue: sem
 * túnel nomeado nem domínio próprio disponível). Quem precisa colar em algum
 * lugar (Activities → URL Mappings / OAuth2 → Redirects no portal do
 * Discord) lê no `docker compose logs -f discord-screen`.
 */
import { spawn } from 'node:child_process';

import { RAIZ, cor } from './env.mjs';
import { garantirEntryPoint, contarEntryPoint } from './entry-point.mjs';
import { abrirTunel } from './tunel.mjs';
import { acompanhar, derrubar, encerrandoAgora } from './processos.mjs';

const linha = (t = '') => console.log(t);
const nota = (t) => linha(`${cor.fraco}${t}${cor.fim}`);

linha();
linha(`${cor.forte}  Sala de Tela · container${cor.fim}`);

const { DISCORD_CLIENT_ID, DISCORD_CLIENT_SECRET } = process.env;

if (DISCORD_CLIENT_ID && DISCORD_CLIENT_SECRET) {
  contarEntryPoint(await garantirEntryPoint(DISCORD_CLIENT_ID, DISCORD_CLIENT_SECRET));
} else {
  nota('  Sem DISCORD_CLIENT_ID/DISCORD_CLIENT_SECRET — atividade do Discord desligada.');
}

let servidorIniciado = false;

function iniciarServidor(origem) {
  if (servidorIniciado) return;
  servidorIniciado = true;

  // Pelo ambiente, e não pelo .env: o servidor lê PUBLIC_ORIGIN uma vez, no
  // arranque, e o endereço acabou de nascer do túnel.
  const env = { ...process.env };
  if (origem) env.PUBLIC_ORIGIN = origem;

  acompanhar(
    'servidor',
    cor.azul,
    spawn(process.execPath, ['server/index.js'], { cwd: RAIZ, stdio: 'pipe', env }),
  );
}

let tunel;
try {
  // rapido: sempre descartável, mesmo que algum dia apareça TUNEL_CONFIG por
  // engano no ambiente — endereço fixo não é o que este modo promete.
  tunel = await abrirTunel({ aoEndereco: iniciarServidor, rapido: true, gravar: false });
} catch (err) {
  linha(`\n${cor.vermelho}  ${err.message}${cor.fim}\n`);
  derrubar(1);
}

if (tunel) {
  acompanhar('tunel', cor.amarelo, tunel);

  setTimeout(() => {
    if (servidorIniciado || encerrandoAgora()) return;
    linha(
      `\n${cor.amarelo}  O túnel demorou a responder — subindo o servidor mesmo assim.${cor.fim}`,
    );
    nota('  Em localhost tudo funciona; só o acesso de fora depende do túnel.');
    iniciarServidor(null);
  }, 45_000).unref();
}
