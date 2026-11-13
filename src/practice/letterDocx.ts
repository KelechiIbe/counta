// A firm's own engagement letter imported from Word. The .docx is opened here in the browser (only word/document.xml is
// read, after checking the sizes the archive declares, so a small file that unpacks to something huge is refused before it
// is unpacked) and turned into blocks; the database checks the blocks like any other letter before they are saved.
import { unzipSync } from 'fflate';
import { docxXmlToBlocks, type LetterBody } from '../../supabase/functions/_shared/letter.ts';

const MAX_FILE = 2 * 1024 * 1024;
const MAX_TOTAL = 20 * 1024 * 1024;
const MAX_DOCUMENT = 8 * 1024 * 1024;
const TOO_LARGE = 'That Word file is too large to import.';

export async function docxToBlocks(file: File): Promise<LetterBody> {
  if (file.size > MAX_FILE) throw new Error(TOO_LARGE);
  const bytes = new Uint8Array(await file.arrayBuffer());
  let total = 0, tooLarge = false;
  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(bytes, {
      filter: (f) => {
        total += f.originalSize;
        if (total > MAX_TOTAL || (f.name === 'word/document.xml' && f.originalSize > MAX_DOCUMENT)) tooLarge = true;
        return !tooLarge && f.name === 'word/document.xml';
      },
    });
  } catch {
    throw new Error('That file is not a Word document (.docx).');
  }
  if (tooLarge) throw new Error(TOO_LARGE);
  const doc = files['word/document.xml'];
  if (!doc) throw new Error('That file is not a Word document (.docx).');
  const body = docxXmlToBlocks(new TextDecoder().decode(doc));
  if (!body.blocks.length) throw new Error('No text was found in that Word file.');
  return body;
}
