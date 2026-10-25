'use client';

import { Printer } from 'lucide-react';

export function PrintButton() {
  return <button type="button" className="btn btn-pri print:hidden" onClick={() => window.print()}><Printer size={16} />In</button>;
}
