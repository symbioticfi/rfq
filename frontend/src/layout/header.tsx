import { ArrowLeftRight, ArrowRight, ChevronDown, Copy, Power, Send } from "lucide-react";
import { type RefObject, type SVGProps, useCallback, useEffect, useId, useRef, useState } from "react";
import { Link } from "react-router";
import { toast } from "sonner";
import { useEnsAvatar, useEnsName } from "wagmi";

import { Jazzicon } from "../components/jazzicon";
import { IS_HOODI_DEPLOYMENT, IS_LOCAL_DEPLOYMENT } from "../config/rfq";
import { useWallet } from "../hooks/use-wallet";
import styles from "./header.module.css";

const BRAND_LINKS = [
  { label: "Home", href: "https://symbiotic.fi/" },
  { label: "Documentation", href: "https://docs.symbiotic.fi/get-started" },
  { label: "Careers", href: "https://jobs.ashbyhq.com/symbiotic" },
  { label: "Blog", href: "https://blog.symbiotic.fi/" },
  { label: "Contact us", href: "https://form.typeform.com/to/DoilGM4j" },
  { label: "Privacy policy", href: "https://app.symbiotic.fi/privacy_policy.pdf" },
] as const;

const PRIMARY_BRAND_LINK = BRAND_LINKS[0];
const SECONDARY_BRAND_LINKS = BRAND_LINKS.slice(1);

const SOCIAL_LINKS = [
  { label: "X", href: "https://x.com/symbioticfi", icon: XLogo, kind: "x" },
  {
    label: "Telegram",
    href: "https://t.me/symbioticannouncements",
    icon: Send,
    kind: "telegram",
  },
  { label: "GitHub", href: "https://github.com/symbioticfi", icon: GitHubLogo, kind: "github" },
] as const;

const MENU_ICON_SIZE = 14;
const HOVER_MENU_CLOSE_DELAY_MS = 140;

function XLogo(props: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" {...props}>
      <path d="M18.901 1.153h3.68l-8.04 9.189L24 22.847h-7.406l-5.8-7.584-6.635 7.584H.476l8.6-9.83L0 1.154h7.594l5.243 6.932 6.064-6.933Zm-1.294 19.487h2.04L6.486 3.254H4.298Z" />
    </svg>
  );
}

function GitHubLogo(props: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" {...props}>
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5a5.4 5.4 0 0 0-1-3.5c.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 2 5 2c-.3 1.15-.3 2.35 0 3.5A5.4 5.4 0 0 0 4 9c0 3.5 3 5.5 6 5.5-.68.76-1 1.78-1 3v4"
      />
      <path strokeLinecap="round" strokeLinejoin="round" d="M9 18c-4.51 2-5-2-7-2" />
    </svg>
  );
}

function isOutside(target: Node, buttonRef: RefObject<HTMLElement | null>, panelRef: RefObject<HTMLElement | null>) {
  return Boolean(
    panelRef.current && !panelRef.current.contains(target) && buttonRef.current && !buttonRef.current.contains(target),
  );
}

export function Header() {
  const brandMenuId = useId();
  const walletMenuId = useId();
  const { ready, isConnected, activateWallet, address, otherWallets, shortAddress, login, switchWallet, logout } =
    useWallet();
  const { data: ensName } = useEnsName({ address: address as `0x${string}` | undefined });
  const { data: avatar } = useEnsAvatar({ name: ensName ?? undefined });
  const [brandMenuOpen, setBrandMenuOpen] = useState(false);
  const [walletMenuOpen, setWalletMenuOpen] = useState(false);
  const brandMenuRef = useRef<HTMLDivElement>(null);
  const brandButtonRef = useRef<HTMLButtonElement>(null);
  const walletMenuRef = useRef<HTMLDivElement>(null);
  const walletButtonRef = useRef<HTMLButtonElement>(null);
  const brandCloseTimerRef = useRef<number | null>(null);
  const walletCloseTimerRef = useRef<number | null>(null);

  const cancelBrandMenuClose = useCallback(() => {
    if (brandCloseTimerRef.current !== null) {
      window.clearTimeout(brandCloseTimerRef.current);
      brandCloseTimerRef.current = null;
    }
  }, []);

  const cancelWalletMenuClose = useCallback(() => {
    if (walletCloseTimerRef.current !== null) {
      window.clearTimeout(walletCloseTimerRef.current);
      walletCloseTimerRef.current = null;
    }
  }, []);

  const openBrandMenu = useCallback(() => {
    cancelBrandMenuClose();
    cancelWalletMenuClose();
    setBrandMenuOpen(true);
    setWalletMenuOpen(false);
  }, [cancelBrandMenuClose, cancelWalletMenuClose]);

  const openWalletMenu = useCallback(() => {
    cancelBrandMenuClose();
    cancelWalletMenuClose();
    setWalletMenuOpen(true);
    setBrandMenuOpen(false);
  }, [cancelBrandMenuClose, cancelWalletMenuClose]);

  const scheduleBrandMenuClose = useCallback(() => {
    cancelBrandMenuClose();
    brandCloseTimerRef.current = window.setTimeout(() => {
      setBrandMenuOpen(false);
      brandCloseTimerRef.current = null;
    }, HOVER_MENU_CLOSE_DELAY_MS);
  }, [cancelBrandMenuClose]);

  const scheduleWalletMenuClose = useCallback(() => {
    cancelWalletMenuClose();
    walletCloseTimerRef.current = window.setTimeout(() => {
      setWalletMenuOpen(false);
      walletCloseTimerRef.current = null;
    }, HOVER_MENU_CLOSE_DELAY_MS);
  }, [cancelWalletMenuClose]);

  const handleClickOutside = useCallback(
    (event: MouseEvent) => {
      const target = event.target as Node;

      if (brandMenuOpen && isOutside(target, brandButtonRef, brandMenuRef)) {
        cancelBrandMenuClose();
        setBrandMenuOpen(false);
      }

      if (walletMenuOpen && isOutside(target, walletButtonRef, walletMenuRef)) {
        cancelWalletMenuClose();
        setWalletMenuOpen(false);
      }
    },
    [brandMenuOpen, walletMenuOpen, cancelBrandMenuClose, cancelWalletMenuClose],
  );

  useEffect(() => {
    if (!brandMenuOpen && !walletMenuOpen) {
      return;
    }

    document.addEventListener("mousedown", handleClickOutside);

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") {
        return;
      }

      if (walletMenuOpen) {
        cancelWalletMenuClose();
        setWalletMenuOpen(false);
        walletButtonRef.current?.focus();

        return;
      }

      if (brandMenuOpen) {
        cancelBrandMenuClose();
        setBrandMenuOpen(false);
        brandButtonRef.current?.focus();
      }
    };

    document.addEventListener("keydown", handleKeyDown);

    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [brandMenuOpen, walletMenuOpen, handleClickOutside, cancelBrandMenuClose, cancelWalletMenuClose]);

  useEffect(
    () => () => {
      cancelBrandMenuClose();
      cancelWalletMenuClose();
    },
    [cancelBrandMenuClose, cancelWalletMenuClose],
  );

  const handleCopyAddress = (walletAddress: string) => {
    navigator.clipboard.writeText(walletAddress);
    toast.success("Address copied");
  };

  const handleCopy = () => {
    if (address) {
      handleCopyAddress(address);
    }
  };

  const handleDisconnect = () => {
    logout();
    setWalletMenuOpen(false);
  };

  const handleSwitchWallet = () => {
    switchWallet();
    setWalletMenuOpen(false);
  };

  const handleActivateWallet = (walletAddress: string) => {
    void activateWallet(walletAddress);
    setWalletMenuOpen(false);
  };

  const walletAvatar = avatar ? (
    <img src={avatar} alt="" className={styles.walletIcon} />
  ) : address ? (
    <Jazzicon address={address} size={18} />
  ) : null;

  return (
    <header className={styles.header}>
      <div className={styles.brandMenuWrapper} onMouseEnter={openBrandMenu} onMouseLeave={scheduleBrandMenuClose}>
        <button
          ref={brandButtonRef}
          className={styles.brandButton}
          onClick={openBrandMenu}
          type="button"
          aria-expanded={brandMenuOpen}
          aria-controls={brandMenuId}
        >
          <span className={styles.lockupFrame}>
            <img src="/lockup.png" alt="Symbiotic" className={styles.lockup} />
          </span>
          <ChevronDown
            size={14}
            aria-hidden="true"
            className={`${styles.brandButtonChevron} ${brandMenuOpen ? styles.brandButtonChevronOpen : ""}`}
          />
        </button>

        {brandMenuOpen && (
          <div
            ref={brandMenuRef}
            id={brandMenuId}
            className={styles.brandMenu}
            aria-label="Symbiotic navigation"
            onMouseEnter={cancelBrandMenuClose}
            onMouseLeave={scheduleBrandMenuClose}
          >
            <div className={styles.brandMenuTopRow}>
              <a
                href={PRIMARY_BRAND_LINK.href}
                target="_blank"
                rel="noopener noreferrer"
                className={`${styles.brandMenuLink} ${styles.brandMenuPrimaryLink}`}
                onClick={() => setBrandMenuOpen(false)}
              >
                {PRIMARY_BRAND_LINK.label}
              </a>

              <div className={styles.brandMenuSocials} aria-label="Symbiotic socials">
                {SOCIAL_LINKS.map((link) => {
                  const Icon = link.icon;
                  const iconClassName =
                    link.kind === "x"
                      ? styles.socialIconX
                      : link.kind === "telegram"
                        ? styles.socialIconTelegram
                        : styles.socialIconGithub;

                  return (
                    <a
                      key={link.label}
                      href={link.href}
                      target="_blank"
                      rel="noopener noreferrer"
                      className={styles.brandMenuSocialLink}
                      aria-label={link.label}
                      title={link.label}
                    >
                      <Icon
                        size={MENU_ICON_SIZE}
                        aria-hidden="true"
                        className={`${styles.menuIcon} ${styles.brandMenuSocialIcon} ${iconClassName}`}
                      />
                    </a>
                  );
                })}
              </div>
            </div>

            <nav className={styles.brandMenuLinks} aria-label="Symbiotic links">
              {SECONDARY_BRAND_LINKS.map((link) => (
                <a
                  key={link.href}
                  href={link.href}
                  target="_blank"
                  rel="noopener noreferrer"
                  className={styles.brandMenuLink}
                  onClick={() => setBrandMenuOpen(false)}
                >
                  {link.label}
                </a>
              ))}
            </nav>

            {/*
                        <div className={styles.themeSwitcher} role="group" aria-label="Theme">
                            Theme choice is temporarily disabled while the swap UI is dark-only.
                        </div>
                        */}
          </div>
        )}
      </div>

      <div className={styles.actions}>
        {IS_LOCAL_DEPLOYMENT || IS_HOODI_DEPLOYMENT ? (
          <Link className={styles.devLink} to="/faucet">
            Faucet
          </Link>
        ) : null}
        {ready && isConnected && shortAddress ? (
          <div className={styles.walletWrapper} onMouseEnter={openWalletMenu} onMouseLeave={scheduleWalletMenuClose}>
            <button
              ref={walletButtonRef}
              className={styles.walletButton}
              onClick={openWalletMenu}
              type="button"
              aria-expanded={walletMenuOpen}
              aria-controls={walletMenuId}
            >
              {walletAvatar}
              {ensName ?? shortAddress}
            </button>
            {walletMenuOpen && (
              <div
                ref={walletMenuRef}
                id={walletMenuId}
                className={styles.walletMenu}
                aria-label="Wallet actions"
                onMouseEnter={cancelWalletMenuClose}
                onMouseLeave={scheduleWalletMenuClose}
              >
                <div className={styles.walletMenuCurrentRow}>
                  <button
                    className={styles.walletMenuCurrentWallet}
                    onClick={handleCopy}
                    type="button"
                    aria-label="Copy current wallet address"
                  >
                    {walletAvatar}
                    <span className={styles.walletMenuAddress}>{ensName ?? shortAddress}</span>
                  </button>
                  <div className={styles.walletMenuActions}>
                    <button
                      className={`${styles.walletMenuAction} ${styles.walletMenuActionCopy}`}
                      onClick={handleCopy}
                      type="button"
                      aria-label="Copy current wallet address"
                    >
                      <Copy size={16} aria-hidden="true" />
                    </button>
                    <button
                      className={`${styles.walletMenuAction} ${styles.walletMenuActionDisconnect}`}
                      onClick={handleDisconnect}
                      type="button"
                      aria-label="Disconnect"
                    >
                      <Power size={16} aria-hidden="true" />
                    </button>
                  </div>
                </div>

                <div className={styles.walletMenuDivider} aria-hidden="true" />

                <div className={styles.walletMenuSectionRow}>
                  <button
                    className={styles.walletMenuSectionTrigger}
                    onClick={handleSwitchWallet}
                    type="button"
                    aria-label="Connect another wallet"
                  >
                    Other wallets
                  </button>
                  <button
                    className={`${styles.walletMenuAction} ${styles.walletMenuActionSwitch}`}
                    onClick={handleSwitchWallet}
                    type="button"
                    aria-label="Connect another wallet"
                  >
                    <ArrowLeftRight size={16} aria-hidden="true" />
                  </button>
                </div>

                {otherWallets.length > 0 ? (
                  <div className={styles.walletMenuWalletList} aria-label="Other connected wallets">
                    {otherWallets.map((wallet) => (
                      <div key={wallet.address} className={styles.walletMenuWalletRow}>
                        <button
                          className={styles.walletMenuWalletCopyButton}
                          onClick={() => handleCopyAddress(wallet.address)}
                          type="button"
                          aria-label={`Copy ${wallet.shortAddress}`}
                        >
                          <Jazzicon address={wallet.address} size={18} />
                          {wallet.shortAddress}
                          <Copy size={16} aria-hidden="true" className={styles.walletMenuWalletCopyIcon} />
                        </button>
                        <button
                          className={`${styles.walletMenuAction} ${styles.walletMenuActionSwitchRight}`}
                          onClick={() => handleActivateWallet(wallet.address)}
                          type="button"
                          aria-label={`Use ${wallet.shortAddress}`}
                        >
                          <ArrowRight size={16} aria-hidden="true" />
                        </button>
                      </div>
                    ))}
                  </div>
                ) : null}
              </div>
            )}
          </div>
        ) : (
          <button className={styles.connectButton} onClick={login} type="button">
            Connect wallet
          </button>
        )}
      </div>
    </header>
  );
}
