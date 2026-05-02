/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package org.apache.polaris.extension.storage.oci;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.apache.avro.Schema;
import org.apache.avro.file.CodecFactory;
import org.apache.avro.SchemaBuilder;
import org.apache.avro.file.DataFileStream;
import org.apache.avro.file.DataFileWriter;
import org.apache.avro.generic.GenericData;
import org.apache.avro.generic.GenericDatumReader;
import org.apache.avro.generic.GenericDatumWriter;
import org.apache.avro.generic.GenericRecord;
import org.apache.iceberg.Snapshot;
import org.apache.iceberg.TableMetadata;
import org.apache.iceberg.io.FileIO;
import org.apache.iceberg.io.InputFile;
import org.apache.iceberg.io.OutputFile;
import org.apache.iceberg.io.PositionOutputStream;
import org.apache.iceberg.io.SeekableInputStream;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

class OciManifestRewriterTest {

  /**
   * End-to-end test: build an in-memory iceberg-shape manifest-list referencing two manifest
   * avros, run the rewriter, assert the rewritten copies have OCI native URIs and the
   * RewrittenPaths captures the original→rewritten mapping.
   */
  @Test
  void rewritesManifestListAndManifestsEndToEnd() throws Exception {
    InMemoryFileIO io = new InMemoryFileIO();

    String manifest1Path = "s3://polaris-iceberg/demo/users/metadata/m1.avro";
    String manifest2Path = "s3://polaris-iceberg/demo/users/metadata/m2.avro";
    String manifestListPath = "s3://polaris-iceberg/demo/users/metadata/snap-42.avro";

    io.put(manifest1Path, manifestAvroWithDataFile("s3://polaris-iceberg/demo/users/data/0.parquet"));
    io.put(manifest2Path, manifestAvroWithDataFile("s3a://polaris-iceberg/demo/users/data/1.parquet"));
    io.put(manifestListPath, manifestListAvro(List.of(manifest1Path, manifest2Path)));

    OciUriRewriter uri = new OciUriRewriter("axydmvgg0v5v", "us-sanjose-1");
    OciManifestRewriter rewriter = new OciManifestRewriter(uri, io);

    // Mock just enough TableMetadata for rewriteAll: snapshots() with one
    // Snapshot whose manifestListLocation() points at our in-memory path.
    Snapshot snapshot = Mockito.mock(Snapshot.class);
    Mockito.when(snapshot.manifestListLocation()).thenReturn(manifestListPath);
    TableMetadata stub = Mockito.mock(TableMetadata.class);
    Mockito.when(stub.snapshots()).thenReturn(List.of(snapshot));

    RewrittenPaths paths = rewriter.rewriteAll(stub);

    assertThat(paths.manifestLists())
        .containsExactly(
            Map.entry(manifestListPath, manifestListPath + ".oci.avro"));
    assertThat(paths.manifests())
        .containsKeys(manifest1Path, manifest2Path);

    // Original files unchanged
    assertThat(extractDataFilePath(io.getBytes(manifest1Path)))
        .startsWith("s3://");

    // Rewritten files have OCI URIs everywhere
    String rewrittenList = io.getAsString(manifestListPath + ".oci.avro");
    assertThat(rewrittenList)
        .doesNotContain("s3://")
        .contains("https://objectstorage.us-sanjose-1.oraclecloud.com/n/axydmvgg0v5v/b/polaris-iceberg/o/");
    assertThat(extractDataFilePath(io.getBytes(manifest1Path + ".oci.avro")))
        .isEqualTo(
            "https://objectstorage.us-sanjose-1.oraclecloud.com"
                + "/n/axydmvgg0v5v/b/polaris-iceberg/o/demo/users/data/0.parquet");
    assertThat(extractDataFilePath(io.getBytes(manifest2Path + ".oci.avro")))
        .isEqualTo(
            "https://objectstorage.us-sanjose-1.oraclecloud.com"
                + "/n/axydmvgg0v5v/b/polaris-iceberg/o/demo/users/data/1.parquet");
  }

  // --- Helpers ----------------------------------------------------------

  private static byte[] manifestAvroWithDataFile(String dataFilePath) throws Exception {
    Schema dataFileSchema =
        SchemaBuilder.record("DataFile")
            .fields()
            .requiredString("file_path")
            .endRecord();
    Schema entrySchema =
        SchemaBuilder.record("ManifestEntry")
            .fields()
            .name("data_file")
            .type(dataFileSchema)
            .noDefault()
            .endRecord();

    GenericData.Record dataFile = new GenericData.Record(dataFileSchema);
    dataFile.put("file_path", dataFilePath);
    GenericData.Record entry = new GenericData.Record(entrySchema);
    entry.put("data_file", dataFile);

    return writeAvro(entrySchema, List.of(entry));
  }

  private static byte[] manifestListAvro(List<String> manifestPaths) throws Exception {
    Schema schema =
        SchemaBuilder.record("ManifestFile")
            .fields()
            .requiredString("manifest_path")
            .endRecord();
    List<GenericData.Record> records = new ArrayList<>();
    for (String mp : manifestPaths) {
      GenericData.Record r = new GenericData.Record(schema);
      r.put("manifest_path", mp);
      records.add(r);
    }
    return writeAvro(schema, records);
  }

  private static byte[] writeAvro(Schema schema, List<GenericData.Record> records)
      throws Exception {
    ByteArrayOutputStream bos = new ByteArrayOutputStream();
    try (DataFileWriter<GenericRecord> writer =
        new DataFileWriter<>(new GenericDatumWriter<>(schema))) {
      writer.setCodec(CodecFactory.nullCodec());
      writer.create(schema, bos);
      for (GenericData.Record r : records) {
        writer.append(r);
      }
    }
    return bos.toByteArray();
  }

  private static String extractDataFilePath(byte[] manifestBytes) throws Exception {
    try (DataFileStream<GenericRecord> stream =
        new DataFileStream<>(new ByteArrayInputStream(manifestBytes), new GenericDatumReader<>())) {
      GenericRecord first = stream.iterator().next();
      GenericRecord df = (GenericRecord) first.get("data_file");
      return df.get("file_path").toString();
    }
  }

  // --- Tiny in-memory FileIO + InputFile/OutputFile ---------------------

  private static final class InMemoryFileIO implements FileIO {
    final Map<String, byte[]> store = new LinkedHashMap<>();

    void put(String path, byte[] bytes) {
      store.put(path, bytes);
    }

    byte[] getBytes(String path) {
      byte[] b = store.get(path);
      if (b == null) throw new AssertionError("no such path: " + path);
      return b;
    }

    String getAsString(String path) {
      return new String(getBytes(path), java.nio.charset.StandardCharsets.UTF_8);
    }

    @Override
    public InputFile newInputFile(String path) {
      byte[] data = store.get(path);
      if (data == null) {
        throw new RuntimeException("Not found: " + path);
      }
      return new InputFile() {
        @Override
        public long getLength() {
          return data.length;
        }

        @Override
        public SeekableInputStream newStream() {
          return new InMemorySeekableStream(data);
        }

        @Override
        public String location() {
          return path;
        }

        @Override
        public boolean exists() {
          return true;
        }
      };
    }

    @Override
    public OutputFile newOutputFile(String path) {
      return new OutputFile() {
        @Override
        public PositionOutputStream create() {
          return createOrOverwrite();
        }

        @Override
        public PositionOutputStream createOrOverwrite() {
          ByteArrayOutputStream bos = new ByteArrayOutputStream();
          return new PositionOutputStream() {
            long pos;

            @Override
            public long getPos() {
              return pos;
            }

            @Override
            public void write(int b) {
              bos.write(b);
              pos++;
            }

            @Override
            public void write(byte[] b, int off, int len) {
              bos.write(b, off, len);
              pos += len;
            }

            @Override
            public void close() {
              store.put(path, bos.toByteArray());
            }
          };
        }

        @Override
        public String location() {
          return path;
        }

        @Override
        public InputFile toInputFile() {
          return newInputFile(path);
        }
      };
    }

    @Override
    public void deleteFile(String path) {
      store.remove(path);
    }
  }

  private static final class InMemorySeekableStream extends SeekableInputStream {
    private final byte[] data;
    private int pos;

    InMemorySeekableStream(byte[] data) {
      this.data = data;
    }

    @Override
    public long getPos() {
      return pos;
    }

    @Override
    public void seek(long newPos) {
      this.pos = (int) newPos;
    }

    @Override
    public int read() {
      if (pos >= data.length) return -1;
      return data[pos++] & 0xff;
    }

    @Override
    public int read(byte[] b, int off, int len) {
      if (pos >= data.length) return -1;
      int n = Math.min(len, data.length - pos);
      System.arraycopy(data, pos, b, off, n);
      pos += n;
      return n;
    }
  }

}
