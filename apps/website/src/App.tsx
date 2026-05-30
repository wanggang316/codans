import Nav from "./components/Nav";
import Hero from "./sections/Hero";
import MultiProject from "./sections/MultiProject";
import WorktreeSection from "./sections/WorktreeSection";
import Extensions from "./sections/Extensions";
import CtaStrip from "./sections/CtaStrip";
import Footer from "./components/Footer";

export default function App() {
  return (
    <div className="relative min-h-screen overflow-x-hidden bg-bg text-ink">
      <Nav />
      <main>
        <Hero />
        <MultiProject />
        <WorktreeSection />
        <Extensions />
        <CtaStrip />
      </main>
      <Footer />
    </div>
  );
}
