import { createHandler } from './_private/auth.mjs';
import { catalog, globalSource } from './_private/catalog.mjs';
import { onRequest as v2 } from './v2.js';
import { onRequest as clash } from './c.js';
import { onRequest as direct } from './tx.js';
import { onRequest as directV2 } from './tx-v2.js';

export const onRequest = createHandler({
  catalog, globalSource,
  handlers: { '/v2': v2, '/c': clash, '/tx': direct, '/tx-v2': directV2 },
});
