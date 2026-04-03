![Symbiotic RFQ](../frontend/public/lockup.png)

# RFQ Integration

This package owns the cross-service integration surface for RFQ:

- multi-service local dev orchestration
- local stack verification
- cross-service integration tests
- live chain/indexer integration checks

Service packages keep only service-local tests and runtime code. Anything that needs multiple RFQ services together belongs here so backend, filler, and indexer are easier to move into separate repos later.
