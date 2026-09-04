use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("不支持的格式: {0}")]
    Unsupported(String),

    #[error("IO 错误: {0}")]
    Io(#[from] std::io::Error),

    #[error("压缩包错误: {0}")]
    Zip(#[from] zip::result::ZipError),

    #[error("XML 解析错误: {0}")]
    Xml(#[from] roxmltree::Error),

    #[error("图片错误: {0}")]
    Image(#[from] image::ImageError),

    #[error("MOBI 解析错误: {0}")]
    Mobi(String),

    #[error("PDF 错误: {0}")]
    Pdf(String),

    #[cfg(feature = "sync")]
    #[error("网络错误: {0}")]
    Http(#[from] reqwest::Error),

    #[error("WebDAV 错误: 状态 {status} - {message}")]
    Dav { status: u16, message: String },

    #[error("无效的 HLC: {0}")]
    BadHlc(String),

    #[error("内容校验失败: 期望 {expected}, 实际 {actual}")]
    Checksum { expected: String, actual: String },

    #[error("其他: {0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, Error>;
