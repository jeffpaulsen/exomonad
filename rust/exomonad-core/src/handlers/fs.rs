//! Filesystem effect handler for the `fs.*` namespace.
//!
//! Uses proto-generated types from `exomonad_proto::effects::fs`.

use crate::effects::{dispatch_fs_effect, EffectError, EffectResult, FilesystemEffects, ResultExt};
use crate::services::filesystem::FileSystemService;
use crate::services::HasProjectDir;
use async_trait::async_trait;
use exomonad_proto::effects::fs::*;

/// Filesystem effect handler.
///
/// Handles all effects in the `fs.*` namespace by delegating to
/// the generated `dispatch_filesystem_effect` function.
pub struct FsHandler {
    service: FileSystemService,
}

impl FsHandler {
    pub fn new(ctx: &impl HasProjectDir) -> Self {
        let service = FileSystemService::new(ctx.project_dir().to_path_buf());
        Self { service }
    }
}

crate::impl_pass_through_handler!(FsHandler, "fs", dispatch_fs_effect);

#[async_trait]
impl FilesystemEffects for FsHandler {
    async fn read_file(
        &self,
        req: ReadFileRequest,
        _ctx: &crate::effects::EffectContext,
    ) -> EffectResult<ReadFileResponse> {
        tracing::info!(path = %req.path, "[Fs] read_file starting");
        let max_bytes = if req.max_bytes <= 0 {
            1_048_576 // 1MB default
        } else {
            req.max_bytes as usize
        };

        let input = crate::services::filesystem::ReadFileInput {
            path: req.path,
            max_bytes,
        };

        let result = self.service.read_file(&input).await.effect_err("fs")?;

        tracing::info!(
            bytes_read = result.bytes_read,
            truncated = result.truncated,
            "[Fs] read_file complete"
        );
        Ok(ReadFileResponse {
            content: result.content,
            bytes_read: result.bytes_read as i64,
            truncated: result.truncated,
            total_size: 0, // Service doesn't return total size yet
        })
    }

    async fn write_file(
        &self,
        req: WriteFileRequest,
        _ctx: &crate::effects::EffectContext,
    ) -> EffectResult<WriteFileResponse> {
        tracing::info!(path = %req.path, content_bytes = req.content.len(), "[Fs] write_file starting");
        let input = crate::services::filesystem::WriteFileInput {
            path: req.path.clone(),
            content: req.content,
            create_parents: req.create_parents,
        };

        let result = self.service.write_file(&input).await.effect_err("fs")?;

        tracing::info!(
            bytes_written = result.bytes_written,
            "[Fs] write_file complete"
        );
        Ok(WriteFileResponse {
            bytes_written: result.bytes_written as i64,
            path: result.path,
        })
    }

    async fn file_exists(
        &self,
        req: FileExistsRequest,
        _ctx: &crate::effects::EffectContext,
    ) -> EffectResult<FileExistsResponse> {
        tracing::info!(path = %req.path, "[Fs] file_exists starting");
        let path = std::path::Path::new(&req.path);
        let exists = path.exists();
        let is_file = path.is_file();
        let is_directory = path.is_dir();

        tracing::info!(exists, is_file, is_directory, "[Fs] file_exists complete");
        Ok(FileExistsResponse {
            exists,
            is_file,
            is_directory,
        })
    }

    async fn list_directory(
        &self,
        req: ListDirectoryRequest,
        _ctx: &crate::effects::EffectContext,
    ) -> EffectResult<ListDirectoryResponse> {
        tracing::info!(path = %req.path, "[Fs] list_directory starting");
        let path = std::path::Path::new(&req.path);
        if !path.is_dir() {
            return Err(EffectError::not_found(format!(
                "Directory not found: {}",
                req.path
            )));
        }

        let mut entries = Vec::new();
        let mut read_dir = tokio::fs::read_dir(path).await.effect_err("fs")?;

        while let Some(entry) = read_dir.next_entry().await.effect_err("fs")? {
            let name = entry.file_name().to_string_lossy().to_string();
            if !req.include_hidden && name.starts_with('.') {
                continue;
            }

            let metadata = entry.metadata().await.effect_err("fs")?;

            let (size, modified_at) = if req.include_metadata {
                let size = metadata.len() as i64;
                let modified = metadata
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);
                (size, modified)
            } else {
                (0, 0)
            };

            entries.push(FileEntry {
                name,
                is_directory: metadata.is_dir(),
                size,
                modified_at,
            });
        }

        let count = entries.len() as i32;
        tracing::info!(count, "[Fs] list_directory complete");
        Ok(ListDirectoryResponse { entries, count })
    }

    async fn delete_file(
        &self,
        req: DeleteFileRequest,
        _ctx: &crate::effects::EffectContext,
    ) -> EffectResult<DeleteFileResponse> {
        tracing::info!(path = %req.path, recursive = req.recursive, "[Fs] delete_file starting");
        let path = std::path::Path::new(&req.path);
        if !path.exists() {
            return Ok(DeleteFileResponse { deleted: false });
        }

        if path.is_dir() {
            if req.recursive {
                tokio::fs::remove_dir_all(path).await.effect_err("fs")?;
            } else {
                tokio::fs::remove_dir(path).await.effect_err("fs")?;
            }
        } else {
            tokio::fs::remove_file(path).await.effect_err("fs")?;
        }

        tracing::info!(path = %req.path, "[Fs] delete_file complete");
        Ok(DeleteFileResponse { deleted: true })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{AgentName, BirthBranch};
    use crate::effects::{EffectContext, EffectHandler};
    use std::path::{Path, PathBuf};
    use tempfile::tempdir;

    struct TestCtx {
        project_dir: PathBuf,
    }

    impl HasProjectDir for TestCtx {
        fn project_dir(&self) -> &Path {
            &self.project_dir
        }
    }

    fn make_handler(dir: &Path) -> FsHandler {
        FsHandler::new(&TestCtx {
            project_dir: dir.to_path_buf(),
        })
    }

    fn test_ctx() -> EffectContext {
        EffectContext {
            agent_name: AgentName::from("test"),
            birth_branch: BirthBranch::from("main"),
            working_dir: std::path::PathBuf::from("."),
        }
    }

    #[test]
    fn test_fs_handler_new() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        assert_eq!(handler.namespace(), "fs");
    }

    #[tokio::test]
    async fn test_read_file() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let file_path = dir.path().join("hello.txt");
        std::fs::write(&file_path, "hello world").unwrap();

        let resp = handler
            .read_file(
                ReadFileRequest {
                    path: file_path.to_string_lossy().to_string(),
                    max_bytes: 0,
                    offset: 0,
                },
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(resp.content, "hello world");
        assert_eq!(resp.bytes_read, 11);
        assert!(!resp.truncated);
    }

    #[tokio::test]
    async fn test_read_file_truncated() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let file_path = dir.path().join("big.txt");
        std::fs::write(&file_path, "abcdefghij").unwrap();

        let resp = handler
            .read_file(
                ReadFileRequest {
                    path: file_path.to_string_lossy().to_string(),
                    max_bytes: 5,
                    offset: 0,
                },
                &ctx,
            )
            .await
            .unwrap();
        // bytes_read reflects original file size, not truncated size
        assert_eq!(resp.bytes_read, 10);
        assert!(resp.truncated);
        assert_eq!(resp.content.len(), 5);
    }

    #[tokio::test]
    async fn test_read_file_nonexistent() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let result = handler
            .read_file(
                ReadFileRequest {
                    path: dir.path().join("nope.txt").to_string_lossy().to_string(),
                    max_bytes: 0,
                    offset: 0,
                },
                &ctx,
            )
            .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_write_file() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let file_path = dir.path().join("out.txt");
        let resp = handler
            .write_file(
                WriteFileRequest {
                    path: file_path.to_string_lossy().to_string(),
                    content: "written".into(),
                    create_parents: false,
                    append: false,
                },
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(resp.bytes_written, 7);
        assert_eq!(std::fs::read_to_string(&file_path).unwrap(), "written");
    }

    #[tokio::test]
    async fn test_write_file_create_parents() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let file_path = dir.path().join("a").join("b").join("c.txt");
        let resp = handler
            .write_file(
                WriteFileRequest {
                    path: file_path.to_string_lossy().to_string(),
                    content: "nested".into(),
                    create_parents: true,
                    append: false,
                },
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(resp.bytes_written, 6);
        assert_eq!(std::fs::read_to_string(&file_path).unwrap(), "nested");
    }

    #[tokio::test]
    async fn test_file_exists() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let file_path = dir.path().join("exists.txt");
        std::fs::write(&file_path, "hello").unwrap();

        let resp = handler
            .file_exists(
                FileExistsRequest {
                    path: file_path.to_string_lossy().to_string(),
                },
                &ctx,
            )
            .await
            .unwrap();
        assert!(resp.exists);
        assert!(resp.is_file);
        assert!(!resp.is_directory);

        let resp_none = handler
            .file_exists(
                FileExistsRequest {
                    path: dir.path().join("none").to_string_lossy().to_string(),
                },
                &ctx,
            )
            .await
            .unwrap();
        assert!(!resp_none.exists);
    }

    #[tokio::test]
    async fn test_file_exists_directory() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let sub = dir.path().join("subdir");
        std::fs::create_dir(&sub).unwrap();

        let resp = handler
            .file_exists(
                FileExistsRequest {
                    path: sub.to_string_lossy().to_string(),
                },
                &ctx,
            )
            .await
            .unwrap();
        assert!(resp.exists);
        assert!(!resp.is_file);
        assert!(resp.is_directory);
    }

    #[tokio::test]
    async fn test_list_directory() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        std::fs::write(dir.path().join("a.txt"), "a").unwrap();
        std::fs::create_dir(dir.path().join("subdir")).unwrap();

        let req = ListDirectoryRequest {
            path: dir.path().to_string_lossy().to_string(),
            include_hidden: false,
            include_metadata: false,
        };
        let resp = handler.list_directory(req, &ctx).await.unwrap();
        assert_eq!(resp.count, 2);
        let names: std::collections::HashSet<_> =
            resp.entries.iter().map(|e| e.name.as_str()).collect();
        assert!(names.contains("a.txt"));
        assert!(names.contains("subdir"));
    }

    #[tokio::test]
    async fn test_list_directory_hidden_files() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        std::fs::write(dir.path().join("visible.txt"), "").unwrap();
        std::fs::write(dir.path().join(".hidden"), "").unwrap();

        // Without include_hidden
        let resp = handler
            .list_directory(
                ListDirectoryRequest {
                    path: dir.path().to_string_lossy().to_string(),
                    include_hidden: false,
                    include_metadata: false,
                },
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(resp.count, 1);
        assert_eq!(resp.entries[0].name, "visible.txt");

        // With include_hidden
        let resp = handler
            .list_directory(
                ListDirectoryRequest {
                    path: dir.path().to_string_lossy().to_string(),
                    include_hidden: true,
                    include_metadata: false,
                },
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(resp.count, 2);
    }

    #[tokio::test]
    async fn test_list_directory_with_metadata() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        std::fs::write(dir.path().join("file.txt"), "12345").unwrap();

        let resp = handler
            .list_directory(
                ListDirectoryRequest {
                    path: dir.path().to_string_lossy().to_string(),
                    include_hidden: false,
                    include_metadata: true,
                },
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(resp.count, 1);
        assert_eq!(resp.entries[0].size, 5);
        assert!(resp.entries[0].modified_at > 0);
    }

    #[tokio::test]
    async fn test_list_directory_nonexistent() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let result = handler
            .list_directory(
                ListDirectoryRequest {
                    path: dir.path().join("nope").to_string_lossy().to_string(),
                    include_hidden: false,
                    include_metadata: false,
                },
                &ctx,
            )
            .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_delete_file() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let file_path = dir.path().join("delete_me.txt");
        std::fs::write(&file_path, "bye").unwrap();

        let resp = handler
            .delete_file(
                DeleteFileRequest {
                    path: file_path.to_string_lossy().to_string(),
                    recursive: false,
                },
                &ctx,
            )
            .await
            .unwrap();
        assert!(resp.deleted);
        assert!(!file_path.exists());
    }

    #[tokio::test]
    async fn test_delete_nonexistent() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let resp = handler
            .delete_file(
                DeleteFileRequest {
                    path: dir.path().join("ghost.txt").to_string_lossy().to_string(),
                    recursive: false,
                },
                &ctx,
            )
            .await
            .unwrap();
        assert!(!resp.deleted);
    }

    #[tokio::test]
    async fn test_delete_directory_recursive() {
        let dir = tempdir().unwrap();
        let handler = make_handler(dir.path());
        let ctx = test_ctx();

        let sub = dir.path().join("to_delete");
        std::fs::create_dir(&sub).unwrap();
        std::fs::write(sub.join("inner.txt"), "").unwrap();

        let resp = handler
            .delete_file(
                DeleteFileRequest {
                    path: sub.to_string_lossy().to_string(),
                    recursive: true,
                },
                &ctx,
            )
            .await
            .unwrap();
        assert!(resp.deleted);
        assert!(!sub.exists());
    }
}
