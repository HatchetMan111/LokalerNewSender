import React, { createContext, useCallback, useContext, useRef, useState } from "react";

const ToastContext = createContext(() => {});

export function useToast() {
  return useContext(ToastContext);
}

export function ToastProvider({ children }) {
  const [toasts, setToasts] = useState([]);
  const idRef = useRef(0);

  const push = useCallback((msg, type = "info") => {
    const id = ++idRef.current;
    setToasts((list) => [...list, { id, msg, type }]);
    setTimeout(() => {
      setToasts((list) => list.filter((t) => t.id !== id));
    }, 4200);
  }, []);

  return (
    <ToastContext.Provider value={push}>
      {children}
      <div className="toast-stack" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast toast-${t.type}`}>
            <span className="toast-icon">{t.type === "ok" ? "✓" : t.type === "err" ? "✗" : "ℹ"}</span>
            {t.msg}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}
