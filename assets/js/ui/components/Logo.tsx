/** The LX mark (priv/static/images/logo-mark.png, transparent) at a given size. */
export function Logo({ size = 24, className = "" }: { size?: number; className?: string }) {
  return <img src="/images/logo-mark.png" alt="" width={size} height={size} className={`shrink-0 select-none ${className}`} draggable={false} />;
}
