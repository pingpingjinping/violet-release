import { useParams, useNavigate, useSearchParams } from 'react-router';
import { useTranslation } from 'react-i18next';
import { useImageList } from '../hooks/useImageList';
import { useViewer } from '../hooks/useViewer';
import { useInsertReadLog, useUpdateReadLog } from '../hooks/useReadHistory';
import { useViewerStore } from '../stores/viewer-store';
import { useAppStore } from '../stores/app-store';
import { ViewerContainer } from '../components/viewer/ViewerContainer';
import { LoadingSpinner } from '../components/common/LoadingSpinner';
import { getProxyImageUrl } from '../api/proxy';
import { cleanupExpired } from '../services/image-cache';
import { getHistory } from '../api/history';
import { useEffect, useState } from 'react';

export function ViewerPage() {
  const { t } = useTranslation();
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const galleryId = parseInt(id!);
  const { data: imageList, isLoading } = useImageList(galleryId);

  const totalPages = imageList?.urls.length ?? 0;
  // URL uses 1-based indexing, convert to 0-based for internal use
  const pageParam = parseInt(searchParams.get('page') || '1');
  const initialPage = Math.max(0, pageParam - 1);
  const { currentPage, goToPage } = useViewer(totalPages, initialPage);

  const insertLog = useInsertReadLog();
  const updateLog = useUpdateReadLog();
  const [logId, setLogId] = useState<number | null>(null);
  const { imageCacheEnabled, imageCacheExpireDays } = useAppStore();

  // Cleanup expired cache on mount
  useEffect(() => {
    if (imageCacheEnabled) {
      cleanupExpired(imageCacheExpireDays).catch(() => {});
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Force hide overlay on mount
  useEffect(() => {
    useViewerStore.setState({ showOverlay: false });
  }, []);

  // ESC key to exit viewer
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        navigate(-1);
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [navigate]);

  // Read the previous session before creating this session's local log.
  useEffect(() => {
    if (!galleryId || totalPages <= 0) return;
    let cancelled = false;
    setLogId(null);
    const open = async () => {
      if (!searchParams.has('page')) {
        const previous = (await getHistory(0, 100000)).logs.find(r => r.Article === String(galleryId));
        if (cancelled) return;
        if (previous && previous.LastPage > 0 && window.confirm(t('activity.resumeConfirm', { page: previous.LastPage + 1 }))) {
          goToPage(Math.min(previous.LastPage, totalPages - 1));
        }
      }
      if (cancelled) return;
      const data = await insertLog.mutateAsync({ Article: String(galleryId), Type: 0 });
      if (!cancelled) setLogId(Number(data.Id));
    };
    void open().catch(() => {});
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [galleryId, totalPages]);

  // Setting the log ID also commits an unchanged initial/resumed page.
  useEffect(() => {
    if (logId == null) return;
    updateLog.mutate({ id: logId, LastPage: currentPage });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentPage, logId]);

  // Update URL without navigation (use 1-based indexing in URL)
  useEffect(() => {
    const url = `/viewer/${galleryId}?page=${currentPage + 1}`;
    window.history.replaceState(null, '', url);
  }, [currentPage, galleryId]);

  if (isLoading) {
    return (
      <div style={{
        position: 'fixed',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        background: '#000',
        zIndex: 100,
      }}>
        <LoadingSpinner />
      </div>
    );
  }

  if (!imageList || imageList.urls.length === 0) {
    return (
      <div style={{
        position: 'fixed',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        background: '#000',
        color: '#fff',
        zIndex: 100,
      }}>
        {t('viewer.noImages')}
      </div>
    );
  }

  const referer = `https://hitomi.la/reader/${galleryId}.html`;
  const proxyUrls = imageList.urls.map((url) => getProxyImageUrl(url, referer));
  const thumbnailUrls = (imageList.smallThumbnails ?? []).map((url) =>
    getProxyImageUrl(url, referer),
  );

  return (
    <ViewerContainer
      galleryId={galleryId}
      imageUrls={proxyUrls}
      thumbnailUrls={thumbnailUrls}
      currentPage={currentPage}
      totalPages={totalPages}
      onPageChange={goToPage}
      onClose={() => navigate(-1)}
    />
  );
}

