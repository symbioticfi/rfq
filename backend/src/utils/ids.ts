/**
 * @dev Returns a new UUID string.
 * @returns A random UUID.
 */
export function newUuid() {
  return crypto.randomUUID();
}
