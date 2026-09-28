/** Runs `find` until it finds an element (a tool window may still be loading), then `then`. */
export function whenThere<T extends Element>(find: () => T | null, then: (el: T) => void, tries = 60, every = 50): void {
  const el = find();
  if (el) then(el);
  else if (tries > 0) setTimeout(() => whenThere(find, then, tries - 1, every), every);
}
