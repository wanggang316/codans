import React from "react";
import ReactDOM from "react-dom/client";
import ChangelogPage from "@/pages/ChangelogPage";
import "./i18n";
import "./styles/globals.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <ChangelogPage />
  </React.StrictMode>,
);
