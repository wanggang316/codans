interface Props {
  size?: number;
  className?: string;
}

export default function Logo({ size = 28, className = "" }: Props) {
  return (
    <img
      src="/logo.png"
      width={size}
      height={size}
      alt="touch-code"
      className={`select-none rounded-[6px] ${className}`}
      draggable={false}
    />
  );
}
