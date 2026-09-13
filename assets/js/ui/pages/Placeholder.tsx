import { Link } from "react-router";
import { Page, TopBar } from "@/ui/shell/Shell";
import { t } from "@/ui/strings";

export function NotFoundPage() {
  return (
    <>
      <TopBar title={t.app} />
      <Page>
        <p className="text-muted-foreground">{t.notFound}</p>
        <Link to="/" className="underline">{t.back}</Link>
      </Page>
    </>
  );
}
