import Nav from "./components/Nav";
import Hero from "./sections/Hero";
import AgentMatrix from "./sections/AgentMatrix";
import Hierarchy from "./sections/Hierarchy";
import Worktree from "./sections/Worktree";
import CliSection from "./sections/CliSection";
import Native from "./sections/Native";
import CtaStrip from "./sections/CtaStrip";
import Footer from "./components/Footer";

export default function App() {
  return (
    <div className="relative min-h-screen overflow-x-hidden bg-bg text-ink">
      <Nav />
      <main>
        <Hero />
        <AgentMatrix />
        <Hierarchy />
        <Worktree />
        <CliSection />
        <Native />
        <CtaStrip />
      </main>
      <Footer />
    </div>
  );
}
