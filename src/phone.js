/**
 * Phone normalization and validation for Spanish mobile numbers.
 */

/**
 * Normalize a raw phone string to 9 digits (without country prefix).
 * Returns null if the input can't be cleaned to a valid 9-digit number.
 */
export function normalizePhone(raw) {
  if (!raw) return null;

  // Remove spaces, dashes, dots, parentheses
  let cleaned = String(raw).replace(/[\s\-.()+]/g, '');

  // Remove country prefix: 0034 or 34 (only when followed by 9 digits)
  if (cleaned.startsWith('0034') && cleaned.length === 13) {
    cleaned = cleaned.slice(4);
  } else if (cleaned.startsWith('34') && cleaned.length === 11) {
    cleaned = cleaned.slice(2);
  }

  // Must be exactly 9 digits
  if (!/^\d{9}$/.test(cleaned)) return null;

  return cleaned;
}

/**
 * Check if a normalized 9-digit phone is a valid Spanish mobile number.
 * Mobile numbers start with 6 or 7.
 */
export function isValidMobile(phone, prefixes = ['6', '7']) {
  if (!phone || phone.length !== 9) return false;
  return prefixes.some(p => phone.startsWith(p));
}
