import makeBlockie from "ethereum-blockies-base64";
import { useMemo } from "react";

type IdenticonProps = {
  readonly address: string;
  readonly size?: number;
};

export function Jazzicon({ address, size = 18 }: IdenticonProps) {
  const src = useMemo(() => makeBlockie(address), [address]);

  return (
    <img
      src={src}
      alt=""
      style={{
        width: size,
        height: size,
        borderRadius: "50%",
        flexShrink: 0,
      }}
    />
  );
}
