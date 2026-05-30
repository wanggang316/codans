import Nav from "./components/Nav";
import Hero from "./sections/Hero";
import CtaStrip from "./sections/CtaStrip";
import Footer from "./components/Footer";

export default function App() {
  return (
    <div className="relative min-h-screen overflow-x-hidden bg-bg text-ink">
      <Nav />
      <main>
        <Hero />
        <CtaStrip />
      </main>
      <Footer />
    </div>
  );
}
